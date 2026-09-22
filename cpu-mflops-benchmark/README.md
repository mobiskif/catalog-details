# CPU MFLOPS Benchmark

Платформенно-независимое Java-приложение для измерения производительности
процессора в мегафлопсах (MFLOPS). Использует только стандартную библиотеку
Java (без внешних зависимостей), запускается на любой платформе с JVM.

## Как это работает

Приложение запускает по одному потоку на каждое доступное ядро процессора
(можно задать вручную) и выполняет в каждом потоке плотный цикл операций с
плавающей точкой двойной точности (умножение, сложение, вычитание, деление).
Перед измерением выполняется прогрев JIT-компилятора. По итогам замера
считается суммарная и средняя на поток производительность в MFLOPS/GFLOPS.

## Сборка

Требуется JDK 8+.

```bash
javac -d out src/CpuMflops.java
printf 'Main-Class: CpuMflops\n' > manifest.txt
jar cfm cpu-mflops-benchmark.jar manifest.txt -C out .
```

Готовый jar-файл: `cpu-mflops-benchmark.jar`.

## Запуск

```bash
java -jar cpu-mflops-benchmark.jar [iterations] [threads] [warmupSeconds]
```

Параметры (все необязательные):

- `iterations` — число итераций на поток за проход (по умолчанию 50 000 000)
- `threads` — число потоков (по умолчанию = число ядер CPU)
- `warmupSeconds` — время прогрева JIT в секундах (по умолчанию 2.0)

Пример:

```bash
java -jar cpu-mflops-benchmark.jar
java -jar cpu-mflops-benchmark.jar 100000000 8 3
```

Пример вывода:

```
=== Java CPU MFLOPS Benchmark ===
JVM        : OpenJDK 64-Bit Server VM 21.0.10
OS         : Linux amd64
CPU cores  : 4
Threads    : 4
Iterations : 50000000 per thread (per pass)

Warming up JIT (2.0s)...
Running benchmark...
Elapsed time: 1.234 s (checksum=..., ignore)

=== Results ===
Total performance : 12345.67 MFLOPS (12.346 GFLOPS)
Per-thread average : 3086.42 MFLOPS
```
