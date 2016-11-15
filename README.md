# crawler

по мотивам <https://github.com/zamotivator/crawler/blob/master/README.md>

example of usage:
```
./crawler.pl --parallel=16 http://yandex.ru/
./crawler.pl --parallel=16 --dir goo http://google.ru/
CRAWLER_DEBUG=1 ./crawler.pl --parallel=4 http://htmlbook.ru/
./crawler.pl http://habrahabr.ru/
```

# потраченное время

8 часов

# постановка задачи


Реализовать web-crawler, рекурсивно скачивающий сайт (идущий по ссылкам вглубь). Crawler должен скачать документ по указанному URL и продолжить закачку по ссылкам, находящимся в документе.
 - Crawler должен поддерживать дозакачку.
 - Crawler должен грузить только текстовые документы -   html, css, js (игнорировать картинки, видео, и пр.)
 - Crawler должен грузить документы только одного домена (игнорировать сторонние ссылки)
 - Crawler должен быть многопоточным (какие именно части параллелить - полностью ваше решение)

Требования специально даны неформально. Мы ходим увидеть, как вы по постановке задаче самостоятельно примете решение, что более важно, а что менее.

На выходе мы ожидаем работающее приложение, которое сможем собрать и запустить.
Мы не ожидаем правильной обработки всех типов ошибок и граничных случаев, вы сами себе должны поставить отсечку "good enough".