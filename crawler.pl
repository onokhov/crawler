#!/usr/bin/env perl

use warnings;
use strict;
use utf8;

use AE;
use JSON qw(from_json to_json);
use Getopt::Long;
use URI;
use URI::Escape;
use HTML::Parser;
use File::Spec;
use File::Basename;
use File::Path qw(make_path);
use Log::Log4perl qw(:easy);
use Encode qw(decode_utf8);
use LWP::UserAgent;
use Fcntl qw(:flock);

#  По ТЗ https://github.com/zamotivator/crawler/blob/master/README.md
#  Замечания:
#    по разным схемам по одинаковому пути могут быть разные документы, а у нас скачается первый попавшийся
#    query_string в ссылках не учитывается. TODO: сделать опциональным
#    Пути без расширения считаются за директории. Такие ссылки, заменяются на локальные index.html
#    По ТЗ картинки не грузятся, поэтому ссылки на них лучше не делать локальными. Требует обсуждения.


Log::Log4perl->easy_init({ level => $ENV{CRAWLER_DEBUG} ? $DEBUG : $INFO, utf8  => 1 });

# глобальные переменные
my @URLS_TO_LOAD;       # сюда складываем урлы для загрузки
my %URLS_IN_PROGRESS;   # здесь храним урлы в процессе загрузки
my %FILES_DONE;         # а здесь уже загруженные урлы
my $TARGET_HOST;        # фильтровать по нему будем
my $UA = LWP::UserAgent->new(); 

# опции командной строки со значениями по умолчанию
my $opt_parallel   = 1;
my $opt_state_file = 'crawler.run';
my $opt_dir        = '.';

GetOptions ("parallel=i" => \$opt_parallel,    # максимальное количество параллелльных процессов закачки
            "state=s"    => \$opt_state_file,  # имя файла в котором сохраняем состояние работы, чтобы после прерывания загрузки её можно было продолжить
            "dir=s"      => \$opt_dir,         # в эту директорию будем загружать
           );

die <<"USAGE" unless $ARGV[0];
Usage:
  $0 [--parallel N] [--state FILE] [--dir DIR] http(s)?://url.to.load
  CRAWLER_DEBUG=1 $0 http(s)?://url.to.load
USAGE

# Валидируем и исправляем, если нужно, параметр 'parallel'. Он должен быть положительным целым числом.
$opt_parallel = abs($opt_parallel) || 1;

push @URLS_TO_LOAD, URI->new( $ARGV[0] )->canonical;
$TARGET_HOST    = $URLS_TO_LOAD[0]->host;

# настраиваем юзерагент перед использованием
$UA->add_handler( response_header => sub {
                      my $type = shift->header('content-type') || 'text/';
                      unless ( $type =~ m{^text/} ) { 
                          DEBUG "пропускаем тип $type";
                          die;  # не будем грузить картинки, видео и другое не текстовое
                      }
                  });    

INFO "Crawler started url: $ARGV[0], parallel: $opt_parallel";
DEBUG "target_host: $TARGET_HOST";
load_state(); # если загрузка была раннее прервана, то восстановим её

my $children_count = 0; # счетчик параллельных процессов. Будем следить, чтоб не превышал заказанное количество.
my $cv = AnyEvent->condvar; # эта переменная будет использована для отслеживания детей
my $wt = AnyEvent->timer (after => 1, interval => 5, cb => \&save_state ); # сохраняем состояние раз в пять секунд
spawn(); # тут рекурсивно плодим параллельные процессы, в которых происходит загрузка
$cv->recv; # ждём, когда всё закончится
unlink $opt_state_file or WARN "Не получилось удалить $opt_state_file: $!";
INFO "Завершили загрузку";
exit;

#
# процедуры
#

sub seen { # для фильтра урлов, чтоб не грузить уже загруженные
    return $FILES_DONE{ url_to_filename(URI->new($_[0])) } || $URLS_IN_PROGRESS{ $_[0] };
}

# в этой процедуре плодим детей в цикле до заданного ограничения
sub spawn {
    @URLS_TO_LOAD = grep !seen($_), @URLS_TO_LOAD; # выбрасываем из массива уже загруженные урлы
    DEBUG ("spawn старт. children_count: $children_count, urls_count: " . @URLS_TO_LOAD);
    while ( @URLS_TO_LOAD and $children_count < $opt_parallel ) { 
        my $url = shift @URLS_TO_LOAD;
        
        my $child_pid = open(my $child_to_read, '-|'); # see perldoc perlipc  Тут происходит fork. Родитель может читать STDOUT ребенка
        die "can't fork: $!" unless defined $child_pid;

        do { download_and_save($url); exit; } unless $child_pid; # в этой строке работает ребенок

        # дальше в процедуре работает родитель
        $URLS_IN_PROGRESS{$url}++;
        $children_count++;
        DEBUG "Запущен ребенок $child_pid";
        INFO  @URLS_TO_LOAD . '/' . (keys %FILES_DONE) . "(p=$children_count) " . decode_utf8(uri_unescape($url));
        $cv->begin;
        
        my $wr; $wr = AnyEvent->io (fh => $child_to_read, poll => 'r', cb => sub {
                                        DEBUG "Читаем новые урлы ребенка $child_pid";
                                        while ( <$child_to_read> ) {
                                            chomp;                                            
                                            next if seen($_) or URI->new($_)->host ne $TARGET_HOST;
                                            push @URLS_TO_LOAD, $_;
                                        }
                                        DEBUG "Прочитали новые урлы от ребенка $child_pid";
                                        $children_count--;
                                        $FILES_DONE{ url_to_filename(URI->new($url)) }++;
                                        delete $URLS_IN_PROGRESS{$url};
                                        spawn(); # возможно появились новые урлы, запустим на скачивание
                                        $cv->end;
                                        undef $wr;
                                    });
    }
    DEBUG ("spawn конец");
}


# Основная процедура ребенка. Загружаем урл, заменяем ссылки на локальные и сохраняем в файл.
# Обнаруженные в документе ссылки для закачки печатаем в STDOUT. Родитель прочитает.

sub download_and_save {
    my $url = URI->new(shift);
    DEBUG "Ребенок $$, задание $url начало";
    my $html = $UA->get($url)->decoded_content;
    my $new_urls = length $html > 0 ? parse_and_save(\$html, $url) : [];
#    DEBUG "Ребенок $$, Загружен $url: $html";
    DEBUG "Ребенок $$ новый урл $_" for grep !seen($_), @$new_urls;
    print "$_\n" for grep !seen($_), @$new_urls;
    DEBUG "Ребенок $$ конец";
}

sub parse_and_save {
    my $html_ref = shift;
    my $base = URI->new(shift);
    my $filename = url_to_filename($base);

    make_path(dirname($filename))     or LOGDIE "Ошибка при создании пути для $filename: $!" unless -d dirname($filename);
    open my $f, '>> :utf8', $filename or LOGDIE "Ошибка при открытии $filename на запись: $!";
    flock($f, LOCK_EX) or do { WARN "Не получается flock на $filename: $!"; return; }; # нужен при параллельной закачке
    seek($f, 0, 0)  or LOGDIE "Ошибка seek на начало $filename: $!";
    truncate($f, 0) or LOGDIE "Ошибка truncate $filename: $!";

    my @urls; # сюда будем складывать найденные ссылки для последующей загрузки

    $$html_ref =~ s{\@include\s+url\((["']*)([^"'\)]+)\1\)}    # css include
                   {  my $url = URI->new_abs($2, $base);
                      my $quote = $1 || '';                      
                      push @urls, $url if $url->scheme =~ /^http/ and $url->host eq $TARGET_HOST;
                      qq{\@include url($quote@{[  url_to_relative($url, $base) ]}$quote)}
                   }gie;

    my $start = sub  {    # заменяем ссылки на локальные. Те, которые собираемся загружать
      my ($tag, $attr, $attrseq, $origtext) = @_;
      unless ($tag =~ /^(?:a|link|script)$/) {
          print $f $origtext;
          return;
      }
      my $name = $tag eq 'script' ? 'src' : 'href';
      if (defined $attr->{$name}) {
          my $url = URI->new_abs($attr->{$name}, $base);
          if ($url->scheme =~ /^http/ and $url->host eq $TARGET_HOST) {
              $attr->{$name} = url_to_relative($url, $base);
              push @urls, $url;
          }
      }
      print $f "<$tag ";
      print $f $_ eq '/' ? ' /' : qq( $_="$attr->{$_}") for @$attrseq;
      print $f '>';
    };

    my $p = HTML::Parser->new( api_version => 3,
                               start_h     => [$start,                 "tagname, attr, attrseq, text"],
                               default_h   => [sub { print $f shift }, "text"],
                           );
    $p->parse($$html_ref);
    return \@urls;
}

sub correct_url_path {
    my $url = shift->clone; 
    $url->path($url->path . '/')          unless $url->path =~ m{(?:\.[^/]+|/)$}; # если нет расширения, считаем url каталогом
    $url->path($url->path . 'index.html') if     $url->path =~ m{/$};             # если каталог, добавляем index.html к пути
    return $url;    
}

sub url_to_filename {
    return File::Spec->catfile($opt_dir, $TARGET_HOST, correct_url_path(shift)->path_segments);
}

sub url_to_relative {
    my $url      = correct_url_path(shift);
    my $base_url = correct_url_path(shift);
    return $url->rel($base_url);
}

sub save_state {
    DEBUG "Сохраняем состояние";
    open my $f, '>', $opt_state_file or LOGDIE "Ошибка при сохранении состояния в $opt_state_file: $!";
    print $f to_json( { START_URL => $ARGV[0],
                        URLS_TO_LOAD => \@URLS_TO_LOAD,
                        URLS_IN_PROGRESS => [ keys %URLS_IN_PROGRESS ],
                        FILES_DONE => [ keys %FILES_DONE ],
                        opt_dir => $opt_dir,
                    } );
}

sub load_state {
    DEBUG "Пробуем загрузить сохраненное ранее состояние";
    return DEBUG "Не нашли сохраненного состояния" unless -e $opt_state_file;
    eval {
        open my $f, '<', $opt_state_file or LOGDIE "Ошибка при открытии $opt_state_file: $!";
        my $json = from_json(<$f>);
        if ( $json->{START_URL} eq $ARGV[0] ) {
            @URLS_TO_LOAD     = (@{$json->{URLS_IN_PROGRESS}}, @{$json->{URLS_TO_LOAD}});
            %FILES_DONE        = map {$_ => 1} @{$json->{FILES_DONE}};
            if ( $opt_dir ne $json->{opt_dir} ) {
                $opt_dir = $json->{opt_dir};
                WARN "путь загрузки изменён на $opt_dir в соответствии с ранее сохраненным";
            }
            unshift @URLS_TO_LOAD, delete $URLS_IN_PROGRESS{$_} for keys %URLS_IN_PROGRESS; # эти надо загружать заново
            INFO "Загрузили сохраненное ранее состояние из $opt_state_file. Продолжаем прерванную загрузку";
        }
        else {
            INFO "Сохраненное ранее состояние не соответствует новому url загрузки. Загружаем сайт заново";
        }
    };
    WARN "Ошибка при загрузке сохраненного ранее состояния: $@" if $@;
}

__END__
постановка задачи

Реализовать web-crawler, рекурсивно скачивающий сайт (идущий по ссылкам вглубь). Crawler должен скачать документ по указанному URL и продолжить закачку по ссылкам, находящимся в документе.

Crawler должен поддерживать дозакачку.
Crawler должен грузить только текстовые документы - html, css, js (игнорировать картинки, видео, и пр.)
Crawler должен грузить документы только одного домена (игнорировать сторонние ссылки)
Crawler должен быть многопоточным
