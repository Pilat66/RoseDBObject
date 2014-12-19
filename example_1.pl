#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use feature qw(say);


=head1 Первоначальная настройка системы

Для выполнения примеров надо произвести несколько простых манипуляций.
=cut

=head2 Необходимые модули

Надо установить модули Module::Load Data::Dump Rose::DB::Object DBD::SQLite.

Я это делаю с помощью App::Cpanminus 
http://search.cpan.org/perldoc?App%3A%3Acpanminus , который так же надо 
установить:

    curl -L http://cpanmin.us | perl - App::cpanminus
    MY_PERL_LIB=~/perl5
    mkdir -p $MY_PERL_LIB
    export PERL_CPANM_OPT="--local-lib=$MY_PERL_LIB"
    export PATH=$MY_PERL_LIB/bin:$PATH
    export PERL5LIB=$MY_PERL_LIB:$MY_PERL_LIB/lib/perl5:$PERL5LIB
    cpanm Module::Load Data::Dump Rose::DB::Object DBD::SQLite

Module::Load позволяет загружать модули во время нормального выполнения кода.
Того же самого можно достичь с помощью Require, но написать load <модуль> проще.

Data::Dump - простой дампер, выводящий структуру данных в более 
компактной форме, чем Data::Dumper, например с использованием функции ddx(). 
Везде, где можно, будем использовать ddx()., 

DBD::SQLite - интерфейс к простой базе данных SQLite3. 

=cut

=head2 База данных SQLite

Для тестов будем использовать  СУБД SQLite3. Надо будет установить её поддержку
в операционной системе, напромер в Debian Wheezy:

    apt-get install sqlite3 libsqlite3-0 


=cut

use DBI;
use Data::Dump qw(ddx pp dd);
use Module::Load;
use Rose::DB;
use Rose::DB::Object;
use Rose::DB::Object::Loader;

=head1 Структура тестовой базы данных 

База данных у нас будет из двух таблиц.   

=cut

my $sql_create = <<END;

CREATE TABLE authors (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT
);

CREATE TABLE books (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT,
    editor_id INTEGER,
    author_id_1 INTEGER,
    author_id_2 INTEGER,
    FOREIGN KEY (editor_id) REFERENCES authors (id) ,
    FOREIGN KEY (author_id_2) REFERENCES authors (id) ,
    FOREIGN KEY (author_id_1) REFERENCES authors (id) 
);

END

=head4 

В таблице books нетривиальный момент то,
что есть два почти одинаковых столбца author_id_1 и author_id_2 - они нужны 
для демонстрации дописывания генератора модулей в разделе
'Создание классов Rose' и 'ORM::ConventionManager'.

=cut

open OUT, '>create.sql' || die($!);
print OUT $sql_create;
close OUT;


=head1 В стиле DBI

Сначала короткий пример работы с нашей базы стандартными средствами. 
Он выполняется в отдельном блоке для локализации переменных. Я создаю 
тестовую базу данных и заполняю её тестовыми данными. Этот пример занимает 
одну страницу текста, следующий пример выполняет то же самое 
в стиле Rose::DB::Object, но занимает в несколько раз больше строк текста :)

=cut

{

  my $dbname_dbi = "test_dbi";

  unlink $dbname_dbi;
  system("sqlite3 $dbname_dbi <create.sql");

  my $dbh = DBI->connect("dbi:SQLite:dbname=$dbname_dbi", "", "");
  $dbh->{AutoCommit} = 0;
  $dbh->do('PRAGMA foreign_keys = ON');

  foreach (1 .. 3) {
    $dbh->do("INSERT INTO authors(name) VALUES(?)", {}, "Author $_");
  }

  foreach (1 .. 3) {
    $dbh->do( <<END, {}, "Book $_", 1, $_);
    INSERT INTO books(name, author_id_1, author_id_2) 
    VALUES(
        ?,
        (SELECT id FROM authors WHERE name like '%'||?),
        (SELECT id FROM authors WHERE name like '%'||?)
    )        
END
  }

  $dbh->commit;

  ddx $dbh->selectall_arrayref("SELECT * FROM authors", {Slice => {}});

# [
#   { id => 1, name => "Author 1" },
#   { id => 2, name => "Author 2" },
#   { id => 3, name => "Author 3" },
# ]

  ddx $dbh->selectall_arrayref("SELECT * FROM books", {Slice => {}});

# [
#   { author_id_1 => 1, author_id_2 => 1, id => 1, name => "Book 1" },
#   { author_id_1 => 1, author_id_2 => 2, id => 2, name => "Book 2" },
#   { author_id_1 => 1, author_id_2 => 3, id => 3, name => "Book 3" },
# ]
#
  $dbh->disconnect;

}

=head1 В стиле Rose::DB::Object

В отличии от предыдущего примера, перед работой с ORM Rose::DB::Object надо 
провести дополнительную работу: 

- подключиться к базе, 

- сформировать несколько служебных классов, корректирующих поведение ORM, 

- превратить существующую структуру базы данных в объектную модель, 

- загрузить эту модель. 
 
Довольно сложный комплекс действий. Собственно использование ORM начинается
с раздела "Основные операции с базой".

Главное, что надо сразу понять о Rose::DB::Object - он (или оно) построен 
на системе статических классов (модулей Perl). Каждой схеме в базе 
соответствует ( в один момент времени ) свой набор модулей, который 
нельзя использовать для манипуляции другой такой же схемой или обращаться
к той же схеме с другим именем пользователя. 

Связано это с тем, что ради простоты использования, каждый модуль 
(отражающий структуру таблицы базы) имеет свой $dbh для доступа к базе 
(точнее $dbh прячется в объекте $db, унаследованном от Rose::DB), 
причём этот $dbh используется неявно в конструкциях типа  

    $p = Product->new(name => 'Sled'); 
    $p->save;

Это конструкция создания новой строки в базе. Мы нигде не указываем о какой 
базе идёт речь - это указывается во время инициализации системы классов.
Правда, указать всё же можно, но тогда нарушается гармония:

	$p = Product->new(db => $db, name => 'Sled');
	
так как этот $db ещё надо как-то хранить, создавать, и вообще заботиться о нём.	
Потом об этом напишу подробнее.

Второе, что надо знать. Я пишу исключительно с использованием 
Rose::DB::Object::Loader - то есть сначала создаём базу данных, потом
Loader строит множество модулей, потом мы их инициализируем и используем.
Теоретически можно модули (классы) создавать и самостоятельно; но для 
больших баз, а с маленькими Rose нет смысла использовать, это слишком сложно. 
Проще сделать скрипт, создающий дерево классов, и выполнять его при каждом 
изменении базы. 

Время от времени задаются в форумах вопросы типа "можно ли обратить процесс, 
то есть создавать структуру базы данных по Rose модели". Ответ на это - можно,
так как модель имеет всё необходимое для этого, но Rose это не делает. И
делать это не нужно, всё таки ORM в Perl это совсем не то же что 
Hibernate в Java. 
 
=cut


=head1 Настройка Rose::DB::Object

=cut

=head2 Дополнительные классы

Дополнительные классы позволят изменить метод подключения к базе данных
и правила автосоздания классов Rose по существующей базе данных.

ORM::DB, ORM::DB_Object, ORM::ConventionManager в настоящем проекте
надо описывать в отдельных файлах. Я их сделаю прямо тут.

=cut

=head3 ORM::DB

ORM::DB содержит описание подключения к нашей базе. 

В данном случае это псевдоподключение, так как будет использоваться метод, 
отличный от стандартного. То, что необходимо - сообщить Rose тип базы данных:

	__PACKAGE__->register_db(
	  driver => 'sqlite',
	);


=cut

package ORM::DB;
use strict;
use base qw(Rose::DB);

__PACKAGE__->use_private_registry;
__PACKAGE__->register_db(driver => 'sqlite',);

1;

=head3 ORM::DB_Object
д
ORM::DB_Object - это тот класс, который rose будет использовать 
вместо Rose::DB::Object. Нам нужно только переопределить метод 
init_db().

=cut

package ORM::DB_Object;

use strict;
use base qw(Rose::DB::Object);

our $DB;

sub init_db {
  my $self = shift;
  return $DB;
}

1;

=head3 ORM::ConventionManager

ORM::ConventionManager переопределяет некоторые алгоритмы создания
классов Rose::DB по существующей структуре базы данных с помощью
Rose::DB::Object::Loader .

auto_foreign_key_name() позволяет изменить стандартные имена для 
ссылки на внешние таблицы, table_to_class() позволяет определить 
имена классов, соответствующих таблицам в модели. Например, для
таблицы authors можно выбрать класс ORM::Authors, ORM::Author,
ORM::authors, ORM::author, или любой другой. По-умолчанию,
Rose::DB::Object::Loader применяет хитрые алгоритмы создания
имён, настолько хитрые, что это приносит больше вреда чем пользы
и создаёт проблемы. Для создания имён есть встроенные флаги, 
но проще всего иметь имена классов, совпадающих с именами таблиц
в нижнем регистре. Но это всё на любителя. Но на практике 
имена таблиц бывают _очень_ разные.

=cut

package ORM::ConventionManager;
use base qw(Rose::DB::Object::ConventionManager);

sub auto_foreign_key_name {
  my ($self, $f_class, $current_name, $key_columns, $used_names) = @_;
  my $name;

  if ($f_class eq 'ORM::authors') {
    $name = 'author_primary'   if ($key_columns->{author_id_1});
    $name = 'author_secondary' if ($key_columns->{author_id_2});
  }
  else {
    $name = Rose::DB::Object::ConventionManager::auto_foreign_key_name(@_);
  }
  return $name;
}

# sub auto_relationship {
# 	my($self, $name, $rel_class, $spec) = @_;
# 	my $relname;

# 	# if ( $rel_class eq 'ORM::authors' ) {
# 	# 	$name = 'author_primary'      if ( $key_columns->{author_id_1} );
# 	# 	$name = 'author_secondary'     if ( $key_columns->{author_id_2} );
# 	# }
# 	# else {
#   		$relname = Rose::DB::Object::ConventionManager::auto_relationship(@_);
# 	# }
# 	use Data::Dump qw(ddx);ddx {$relname=>[$name, $rel_class, $spec]};
#   return $relname;
# }

sub table_to_class {
  my ($self, $table, $prefix, $plural) = @_;
  $table = lc $table;
  return ($prefix || '') . $table;
}

1;



package main;

my $dbname_rose = "test_rose";

unlink $dbname_rose;
system("sqlite3 $dbname_rose <create.sql");

=head2 Подключение к базе данных, создание объекта Rose::DB

=cut

=head3 $dbh

=cut

my $dbh = DBI->connect("dbi:SQLite:dbname=$dbname_rose", "", "");
$dbh->{AutoCommit} = 0;

=head3 private_pid и private_tid

Rose::DB проверяет параметры private_pid и private_tid, поэтому надо их 
создать.

=cut

$dbh->{'private_pid'} = $$;
$dbh->{'private_tid'} = threads->tid if ($INC{'threads.pm'});

=head3 $schema

$schema содержит имя схемы базы данных.

У нас может быть несколько схем с одинаковой структурой, и мы можем указать,
с какой схемой нужно работать. $db->schema($schema) можно вызывать в любой
момент. SQLite3 не имеет схем, Так что в этом примере $schema=undef.

=cut

my $schema = undef;

my $db = ORM::DB->new();
$ORM::DB_Object::DB = $db;

$db->dbh($dbh);
$db->schema($schema) if $schema;

my $module_dir = './ormlib_auto';

=head4

В директории ormlib_auto будут лежать сгенерированные модули
описания базы данных. Перед созданием модулей надо либо очистить эту 
директорию, либо обеспечить её отсутствие в @INC.

=cut

#system("rm -Rf $module_dir"); # надо сделать перед созданием модулей
system("mkdir -p $module_dir");

my $loader = Rose::DB::Object::Loader->new(
  db                 => $db,
  db_schema          => $schema,
  module_dir         => $module_dir,
  class_prefix       => 'ORM',
  db_class           => 'ORM::DB',
  base_classes       => ['ORM::DB_Object'],
  convention_manager => 'ORM::ConventionManager',

# include_views можно и установить в 1, но будут глюки.
# Да и Rose любит иметь приватные ключи, роль которых будет исполнять
# столбец из view, выбранный случайным образом.
  include_views => 0,

# include_tables можно не указать, тогда будут использоваться все таблицы
# ( если require_primary_key==1, то только те таблицы,
# у которых есть primary key)
  include_tables => [qw{ books authors }],

# exclude_tables содержит список таблиц, для которых
# не нужно создавать классы
  exclude_tables => [],

# require_primary_key позволяет указать, создавать ли классы
# для таблиц без private key. Таблицы без primary key пораждают глюки,
# поэтому лучше их не загружать. Ну или аккуратно следить за тем,
# чтобы их использовать только в ::Manager-> запросах.
  require_primary_key => 1,

# warn_on_missing_pk порождает сообщения о потенциальных проблемных таблицах
#warn_on_missing_pk  => 1,

);

=head3 Создание классов Rose

Классы создать можно двумя способами: вызвать $loader->make_modules 
или $loader->make_classes(). Первый метод создаст файлы с модулями Perl в 
указанной module_dir директории, второй только создаст и загрузит сами классы.

Есть соблазн всегда пользоваться только make_classes() и не замусоривать 
файловую систему. Делать это не надо по двум причинам: 

	1) изучение созданных модулей крайне полезно для отладки,
	2) создание классов на базах данных с большим числом таблиц 
	   крайне ресурсоёмкое занятие. Создание классов  может занимать 
	   20 секунд, а их загрузка из файлов одну секунду.

Дополнительно о фрагменте:

  post_init_hook => sub {
    my $meta = shift;
    $meta->{allow_inline_column_values} = 1;
  },

Очень хорошая особенность Rose - он допукскает вмешиваться в работу его
компонентов на разных стадиях, например в данном случае после создания 
метаинформации для генерации объекта, соответствующего таблице, можно
эту метаинформацию немного подправить. Конкретно allow_inline_column_values в 
данном случае не нужно ни для чего, это только демонстрация. Вообще очень
полезная опция, Rose может сам установить значения по-умолчанию для некоторых 
столбцов, для которых в баые указан параметр default, а может позволить 
выполнить это самой СУБД. Причина простая - некоторые default значения в базе
на самом деле не константы, а функции (now() d PostgreSQL, SYSDATE в Oracle),
и Rose далеко не всегда справляется сам с опознанием таких объектов.

Rose::DB::Object::Loader имеет кучу флагов, рекомендую почитать о них.
Так же полезно посмотреть исходники - они небольшие по размеру, и позволяют
понять некоторые нетривиальные вещи.

=cut

#$loader->make_classes(db => $db,);

my @classes = $loader->make_modules(
  db             => $db,
  post_init_hook => sub {
    my $meta = shift;
    $meta->{allow_inline_column_values} = 1;
  },
);

ddx @classes;

#   "ORM::authors",
#   "ORM::authors::Manager",
#   "ORM::books",
#   "ORM::books::Manager",


push @INC, 'ormlib_auto';

=head3 Подключение классов ORM::

В данном примере загружать классы не нужно, так как Loader их уже загрузил.
Но в реальности Loader запускается один раз и сохраняет классы в файлах,
потом классы только загружаются без вызова Loader. 

Ещё надо не забывать загружать ORM::DB, ORM::DB_Object, ORM::ConventionManager.
Мы их уже загрузили, да и вообще их нет в файловой системе, так что это 
не делаем, но помним что в реальном проекте сделать надо, например

    foreach(@classes){
        load($_);
    }

=cut

foreach (1 .. 3) {
  my $author = ORM::authors->new(name => "Author $_");
  $author->save();

}

ddx $dbh->selectall_arrayref("SELECT * FROM authors", {Slice => {}});

#   { id => 1, name => "Author 1" },
#   { id => 2, name => "Author 2" },
#   { id => 3, name => "Author 3" },

#my $authors = ORM::authors::Manager->get_authors();
#ddx $authors;

foreach (1 .. 3) {
  ORM::books->new(
    name             => "Book $_",
    editor           => ORM::authors->new(id => 1)->load,
    author_primary   => ORM::authors->new(id => 1)->load,
    author_secondary => ORM::authors->new(id => $_)->load,
  )->save();
}

ddx $dbh->selectall_arrayref("SELECT * FROM books", {Slice => {}});

#   { author_id_1 => 1, author_id_2 => 1, id => 1, name => "Book 1" },
#   { author_id_1 => 1, author_id_2 => 2, id => 2, name => "Book 2" },
#   { author_id_1 => 1, author_id_2 => 3, id => 3, name => "Book 3" },


=head1 Основные операции с базой 

Теперь быстренько пройдёмся по  Rose::DB::Object::Tutorial . У нас есть таблицы
'authors' и 'books'. Над ними и поработаем.

=cut

=head3 Load

Загрузим автора, которого только что создали, и проверим, есть ли такой.
ORM::author->new(id=>1) только создаёт объект в памяти, чтобы наполнить его 
данными из базы, надо вызвать функцию soad(). Чтобы записать в базу - save().

=cut

my $author = ORM::authors->new(id => 1);
unless ($author->load()) {
  die("Нет такого автора");

  # но мы-то знаем что такой автор есть.
}

=head4

Но это загрузка только одного объекта, По его уникальному идентификатору.
Можно загрузить несколько объектов, выполнив для них SQL запрос.
Подробно язык запросов описан в Rose::DB::Object::Manager.

Загрузка нескольких объектов выполняется двумя способами - аналоги функций 
DBI $dbh->selectall_arrayref() и $sth->fetchrow_hashref(). Первый способ 
подходит для небольших выборок, но он должен быть существенно быстрее второго,
второй не загружает сразу все объекты в память, поэтому позволяет обработать 
любые объёмы информации. Сначала первый способ:

=cut

my $authors = ORM::authors::Manager->get_authors(
  query => [or => [name => {'like' => '%1%'}, name => {'like' => '%2%'},],],
  select => ['name'],
  limit  => 2,
  offset => 0,
  debug  => 1
);

=head4

На экран выводится текст запроса, который пойдёт в базу, и подставляемые 
в него параметры:

    SELECT 
    t1.name
    FROM
      authors t1
    WHERE
      (
        t1.name LIKE ? OR
        t1.name LIKE ?
      )
    LIMIT 2 OFFSET 0 (%1%, %2%)


Опции:

 debug=>1 заставит Rose вывести на консоль текст сформированного запроса,
 limit=1 - вывести одну строку, начиная с offset строк,
 offset=>0 - пропустить ноль строк
 select=>['name'] - выбрать только столбец 'name'
 
В $authors будет содержаться массив объектов, соответствующих выбранным 
строкам таблицы.

=cut

ddx map { $_->name } @$authors;

# ("Author 1", "Author 2")

=head4

Теперь второй способ, создадим итератор: разница только в функции 
get_authors_iterator() для выборки объектов.

=cut

my $authors = ORM::authors::Manager->get_authors_iterator(
  query => [or => [name => {'like' => '%1%'}, name => {'like' => '%2%'},],],
  select => ['name'],
  limit  => 2,
  offset => 0,
  debug  => 1
);

while (my $author = $authors->next) {
  ddx [$author->id, $author->name];
}
ddx "Total row(s):" => $authors->total;


=head4

Вне зависимости от метода, которым мы выбираем записи, мы получаем объекты, 
унаследованные от Rose::DB::Object - один объект, или массив объектов. 

=cut

=head2 Get and set column values

Для каждого столбца таблицы создаётся функция (getter/setter) с  именем,
по умолчанию совпадающим с именем столбца (можно изменить в ConventionManager). 

Не забываем, что мало вызвать $author->name('Author 1 New Name') , надо после 
этого сделать $author->save() и, возможно, $dbh->commit() (в нашем случае 
точно надо, так как базу мы открывали с опцией AutoCommit => 0). 
  
=cut

my $author = ORM::authors->new(id => 1);
$author->load();
ddx $author->name();
$author->name('Author 1 New Name');
ddx $author->name();

ddx $dbh->selectall_arrayref("SELECT * FROM authors", {Slice => {}});

#   { id => 1, name => "Author 1" },
#   { id => 2, name => "Author 2" },
#   { id => 3, name => "Author 3" },

=head4

Почему-то в базе ничего не изменилось... А, мы не сделали ->save() !!!

=cut


$author->save();
ddx $dbh->selectall_arrayref("SELECT * FROM authors", {Slice => {}});

#   { id => 1, name => "Author 1 New Name" },
#   { id => 2, name => "Author 2" },
#   { id => 3, name => "Author 3" },


=head4

ОЧЕНЬ ВАЖНЫЙ МОМЕНТ!!!

Много крови мне попортило вот что: если мы создадим таблицу с DEFAULT <функция>,
например (date_start DATE DEFAULT SYSDATE), то Rose по-умолчанию будет 
генерировать запросы типа

  INSERT INTO table (date_start) VALUES ('SYSDATE')
    
а мы-то ожидали 

  INSERT INTO table (date_start) VALUES (SYSDATE)

Регулируется это параметром allow_inline_column_values метаинформации,
например при автогенерации Loader'ом можно сделать так:

  my @classes = $loader->make_modules(
	  db => $db,
	  post_init_hook => sub {
		  my $meta = shift;
		  $meta->{allow_inline_column_values}=1;
	  },
  );

Другая проблема - почему-то Rose делает из 'SYSDATE' 'SYSDATE ' в некоторых 
случаях (наверно не только SYSDATE)

      foreach my $column (keys %{$meta->{columns}}) {
        my $c = $meta->{columns}->{column};
        next unless defined $c->{default}; 
        $c->{default} = 'SYSDATE'
          if $c->{default} eq 'SYSDATE ';
      }

Мы после стандартного создания класса можем его подправить!

=cut

=head3 Insert

Добавление данных мы уже делали во время инициализации базы, сделаем ещё раз:

=cut

my $new_author = ORM::authors->new(name => "Author 4");
$new_author->save();
ddx $dbh->selectall_arrayref("SELECT * FROM authors", {Slice => {}});

#   { id => 1, name => "Author 1 New Name" },
#   { id => 2, name => "Author 2" },
#   { id => 3, name => "Author 3" },
#   { id => 4, name => "Author 4" },

=head4

ОЧЕНЬ ВАЖНЫЙ МОМЕНТ!!!

при создании строк в таблице надо как-то задать значение для PRIMARY KEY 
столбцов. Можно сделать это в явном виде. Rose может сделать это автоматически, 
при соблюдении некоторых условий. Например, для PostgreSQL первичные ключи 
задаются с типом serial, который СУБД разворачивает в тип Integer (или BigInt),
и создаёт последовательность с именем в стандартном формате. У MySQL есть
встроенный тип AUTO_INCREMENT. У Oracle нет ничего, поэтому Rose предполагает,
что для первичных ключей есть последовательность с именем

  my $name = join('_', $table, $column, 'seq');

Имя генерируется в ConventionManager. Если Ваши имена последовательностей 
строятся иначе, можно в ORM::ConventionManager переназначить функции 
auto_primary_key_column_sequence_name() и auto_column_sequence_name() из
Rose::DB::Object::ConventionManager. 

=cut

=head3 Обновление

Обновление так же просто - загружаем, Обновляем, Сохраняем.

=cut

my $author = ORM::authors->new(id => 1);
$author->load();
$author->name('Author 1 New New Name');
$author->save();
$author->load();

=head4

Можно вызывать  update() вместо save() и load(). Единственное, о чём надо помнить - нельзя вызвать update() 
для несозданного в базе объекта, а save() можно - он сам поймёт, надо сделать *INSERT INTO* или *UPDATE SET* SQL команду.

Также в save() и update() можно указать ряд флагов, самый интересный из которых - save(changes_only=>1) или 
load(changes_only=>1). changes_only заставляет сохранять только изменившиеся столбцы. 
meta содержит дефолтное значение для этого флага - default_update_changes_only.

Если что-то хотим сделать потом с объектом, иногда надо повторно 
прочитать его из базы - при сохранении он мог быть изменён триггером.

Если надо обновить несколько объектов, используем субкласс ::Manager :

=cut

my $num_rows_updated = ORM::authors::Manager->update_authors(
  set   => {name => {sql => "name || ' update'"}},
  where => [id   => 1],
  debug => 1
);

ddx $dbh->selectall_arrayref("SELECT * FROM authors", {Slice => {}});

#   { id => 1, name => "Author 1 New New Name update" },
#   { id => 2, name => "Author 2" },
#   { id => 3, name => "Author 3" },
#   { id => 4, name => "Author 4" },

=head3 Удаление

Удалять можно один объект или группу объектов. Сначала удалим один объект: 

=cut 

ddx $dbh->selectall_arrayref("SELECT * FROM authors", {Slice => {}});

#   { id => 1, name => "Author 1 New New Name" },
#   { id => 2, name => "Author 2" },
#   { id => 3, name => "Author 3" },
#   { id => 4, name => "Author 4" },

my $author = ORM::authors->new(id => 4);
$author->delete();
ddx $dbh->selectall_arrayref("SELECT * FROM authors", {Slice => {}});

#   { id => 1, name => "Author 1 New New Name" },
#   { id => 2, name => "Author 2" },
#   { id => 3, name => "Author 3" },


=head4

Метод new() ждёт, как и обычно, уникальный столбец
(PRIMARY KEY или INDEX UNIQUE).

Теперь удалим несколько объектов. Но так как все авторы связаны с книгами, 
сначала сделаем несколько новых авторов, только для удаления:

=cut

foreach (1 .. 3) {
  my $author = ORM::authors->new(name => "Author for removing $_");
  $author->save();
}
ddx $dbh->selectall_arrayref("SELECT * FROM authors", {Slice => {}});

#   { id => 1, name => "Author 1 New New Name" },
#   { id => 2, name => "Author 2" },
#   { id => 3, name => "Author 3" },
#   { id => 5, name => "Author for removing 1" },
#   { id => 6, name => "Author for removing 2" },
#   { id => 7, name => "Author for removing 3" },

my $num_rows_deleted
  = ORM::authors::Manager->delete_authors(where => [id => {ge => '5'}],);

ddx $dbh->selectall_arrayref("SELECT * FROM authors", {Slice => {}});

#   { id => 1, name => "Author 1 New New Name" },
#   { id => 2, name => "Author 2" },
#   { id => 3, name => "Author 3" },


=head2 Более сложные операции - задействуем связи между объектами

Наши книги имеют по паре авторов и одного редактора editor. 

=cut

ddx $dbh->selectall_arrayref("SELECT * FROM books", {Slice => {}});

#   { author_id_1 => 1, author_id_2 => 1, editor_id => 1, id => 1, name => "Book 1" },
#   { author_id_1 => 1, author_id_2 => 2, editor_id => 1, id => 2, name => "Book 2" },
#   { author_id_1 => 1, author_id_2 => 3, editor_id => 1, id => 3, name => "Book 3" },

my $book = ORM::books->new(id => 2)->load;
ddx $book->editor_id, $book->editor->name;

# Rose_DB_Object.pl:721: (1, "Author 1 New New Name update")
ddx $book->author_id_1, $book->author_primary->name;

# Rose_DB_Object.pl:722: (1, "Author 1 New New Name update")
ddx $book->author_id_2, $book->author_secondary->name;

# Rose_DB_Object.pl:723: (2, "Author 2")

=head4

Мы можем выбирать объекты, на которые ссылаемся, автоматически, по мере 
потребности. Побочный эффект от этого  - дополнительные SQL запросы,
то есть злоупотреблять этим нельзя. Правде, есть кэширование, но оно не панацея.
Установим Rose::DB::Object::Debug в 1 и посмотрим как это выглядит:
=cut

#!perl
$Rose::DB::Object::Debug = 1;
my $book = ORM::books->new(id => 2)->load;

#SELECT author_id_2, editor_id, author_id_1, name, id
#FROM books WHERE id = ? - bind params: 2

ddx $book->editor_id, $book->editor->name;

#SELECT name, id FROM authors WHERE id = ? - bind params: 1

$Rose::DB::Object::Debug = 0;


$dbh->commit;
$dbh->disconnect;
