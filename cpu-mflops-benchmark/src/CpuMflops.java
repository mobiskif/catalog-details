import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.*;

/**
 * Platform-independent CPU floating-point performance benchmark.
 * Measures sustained double-precision FLOPS (millions of floating point
 * operations per second) using multiple threads, one per available core.
 */
public final class CpuMflops {

    private static final int OPS_PER_ITERATION = 8; // FLOPs performed per loop body

    public static void main(String[] args) {
        long iterations = parseLongArg(args, 0, 50_000_000L);
        int threads = parseIntArg(args, 1, Runtime.getRuntime().availableProcessors());
        double warmupSeconds = parseDoubleArg(args, 2, 2.0);

        System.out.println("=== Java CPU MFLOPS Benchmark ===");
        System.out.println("JVM        : " + System.getProperty("java.vm.name") + " " + System.getProperty("java.version"));
        System.out.println("OS         : " + System.getProperty("os.name") + " " + System.getProperty("os.arch"));
        System.out.println("CPU cores  : " + Runtime.getRuntime().availableProcessors());
        System.out.println("Threads    : " + threads);
        System.out.println("Iterations : " + iterations + " per thread (per pass)");
        System.out.println();

        System.out.println("Warming up JIT (" + warmupSeconds + "s)...");
        warmup(warmupSeconds);

        System.out.println("Running benchmark...");
        double totalMflops = runBenchmark(threads, iterations);

        System.out.println();
        System.out.println("=== Results ===");
        System.out.printf("Total performance : %.2f MFLOPS (%.3f GFLOPS)%n", totalMflops, totalMflops / 1000.0);
        System.out.printf("Per-thread average : %.2f MFLOPS%n", totalMflops / threads);
    }

    private static void warmup(double seconds) {
        long deadline = System.nanoTime() + (long) (seconds * 1_000_000_000L);
        double a = 1.0000001, b = 0.9999999, c = 1.0;
        while (System.nanoTime() < deadline) {
            c = flopKernel(a, b, c, 200_000L);
        }
        if (c == Double.NaN) {
            System.out.println(c); // prevent dead-code elimination
        }
    }

    private static double runBenchmark(int threads, long iterationsPerThread) {
        ExecutorService pool = Executors.newFixedThreadPool(threads);
        List<Future<Double>> futures = new ArrayList<>();

        long start = System.nanoTime();
        for (int t = 0; t < threads; t++) {
            final long seed = 1000 + t;
            futures.add(pool.submit(() -> flopKernel(1.0000001 + seed * 1e-9, 0.9999999, 1.0, iterationsPerThread)));
        }

        double sink = 0.0;
        for (Future<Double> f : futures) {
            try {
                sink += f.get();
            } catch (InterruptedException | ExecutionException e) {
                Thread.currentThread().interrupt();
                throw new RuntimeException(e);
            }
        }
        long elapsedNanos = System.nanoTime() - start;
        pool.shutdown();

        double elapsedSeconds = elapsedNanos / 1_000_000_000.0;
        double totalFlops = (double) threads * iterationsPerThread * OPS_PER_ITERATION;
        double mflops = (totalFlops / elapsedSeconds) / 1_000_000.0;

        System.out.printf("Elapsed time: %.3f s (checksum=%.6f, ignore)%n", elapsedSeconds, sink);
        return mflops;
    }

    /**
     * Tight loop of double-precision arithmetic. Each iteration performs
     * OPS_PER_ITERATION floating point operations (multiply/add/subtract/divide).
     * Values are chosen to avoid overflow/underflow and to prevent the JIT
     * from constant-folding the loop away.
     */
    private static double flopKernel(double a, double b, double c, long iterations) {
        double x = a, y = b, z = c;
        for (long i = 0; i < iterations; i++) {
            x = x * a + b;
            y = y * b + c;
            z = z * c + a;
            x = (x - y) / (z + 1.0000001);
        }
        return x + y + z;
    }

    private static long parseLongArg(String[] args, int idx, long def) {
        return args.length > idx ? Long.parseLong(args[idx]) : def;
    }

    private static int parseIntArg(String[] args, int idx, int def) {
        return args.length > idx ? Integer.parseInt(args[idx]) : def;
    }

    private static double parseDoubleArg(String[] args, int idx, double def) {
        return args.length > idx ? Double.parseDouble(args[idx]) : def;
    }
}
