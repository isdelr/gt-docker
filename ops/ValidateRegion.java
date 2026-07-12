import java.io.ByteArrayInputStream;
import java.io.DataInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.RandomAccessFile;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.zip.GZIPInputStream;
import java.util.zip.InflaterInputStream;

public final class ValidateRegion {
    private static final int SECTOR_BYTES = 4096;
    private static final Pattern REGION_NAME = Pattern.compile("r\\.(-?\\d+)\\.(-?\\d+)\\.mca");

    private ValidateRegion() {}

    public static void main(String[] args) throws Exception {
        if (args.length == 2 && args[0].equals("--scan")) {
            scanTree(Path.of(args[1]));
            return;
        }

        if (args.length != 3) {
            System.err.println("Usage: ValidateRegion REGION_FILE CHUNK_X CHUNK_Z");
            System.err.println("   or: ValidateRegion --scan WORLD_DIRECTORY");
            System.exit(64);
        }

        String regionPath = args[0];
        int chunkX = Integer.parseInt(args[1]);
        int chunkZ = Integer.parseInt(args[2]);

        try {
            byte[] payload = readChunk(regionPath, chunkX, chunkZ);
            int tileEntities = validatePayload(payload, chunkX, chunkZ);
            System.out.printf(
                    "VALID file=%s chunk=%d,%d nbtBytes=%d tileEntities=%d%n",
                    regionPath, chunkX, chunkZ, payload.length, tileEntities);
        } catch (Exception error) {
            reportInvalid(regionPath, chunkX, chunkZ, error);
            System.exit(2);
        }
    }

    private static void scanTree(Path root) throws Exception {
        AtomicInteger regions = new AtomicInteger();
        AtomicInteger chunks = new AtomicInteger();
        AtomicInteger invalid = new AtomicInteger();

        try (var paths = Files.walk(root)) {
            paths.filter(Files::isRegularFile)
                    .filter(path -> REGION_NAME.matcher(path.getFileName().toString()).matches())
                    .sorted()
                    .forEach(path -> {
                        Matcher matcher = REGION_NAME.matcher(path.getFileName().toString());
                        if (!matcher.matches()) return;
                        int regionX = Integer.parseInt(matcher.group(1));
                        int regionZ = Integer.parseInt(matcher.group(2));
                        regions.incrementAndGet();
                        for (int localZ = 0; localZ < 32; localZ++) {
                            for (int localX = 0; localX < 32; localX++) {
                                int chunkX = regionX * 32 + localX;
                                int chunkZ = regionZ * 32 + localZ;
                                try {
                                    byte[] payload = readChunk(path.toString(), chunkX, chunkZ);
                                    if (payload == null) continue;
                                    chunks.incrementAndGet();
                                    validatePayload(payload, chunkX, chunkZ);
                                } catch (Exception error) {
                                    invalid.incrementAndGet();
                                    reportInvalid(path.toString(), chunkX, chunkZ, error);
                                }
                            }
                        }
                    });
        }

        System.out.printf(
                "SCAN regions=%d chunks=%d invalid=%d root=%s%n",
                regions.get(), chunks.get(), invalid.get(), root);
        if (invalid.get() > 0) System.exit(2);
    }

    private static int validatePayload(byte[] payload, int chunkX, int chunkZ) throws Exception {
        if (payload == null) throw new IOException("chunk is not allocated");
        dh root = du.a(
                new DataInputStream(new ByteArrayInputStream(payload)),
                new ds(64L * 1024 * 1024));
        if (!root.b("Level", 10)) {
            throw new IOException("root compound does not contain a Level compound");
        }
        dh level = root.m("Level");
        int storedX = level.f("xPos");
        int storedZ = level.f("zPos");
        if (storedX != chunkX || storedZ != chunkZ) {
            throw new IOException("stored coordinates are " + storedX + "," + storedZ);
        }
        return level.c("TileEntities", 10).c();
    }

    private static void reportInvalid(String path, int chunkX, int chunkZ, Exception error) {
        System.err.printf(
                "INVALID file=%s chunk=%d,%d error=%s: %s%n",
                path, chunkX, chunkZ, error.getClass().getName(), error.getMessage());
    }

    private static byte[] readChunk(String path, int chunkX, int chunkZ) throws IOException {
        int index = Math.floorMod(chunkX, 32) + Math.floorMod(chunkZ, 32) * 32;
        try (RandomAccessFile region = new RandomAccessFile(path, "r")) {
            region.seek(index * 4L);
            int location = region.readInt();
            int sectorOffset = location >>> 8;
            int sectorCount = location & 0xff;
            if (sectorOffset < 2 || sectorCount == 0) {
                return null;
            }

            region.seek(sectorOffset * (long) SECTOR_BYTES);
            int length = region.readInt();
            int compression = region.readUnsignedByte();
            if (length < 1 || length > sectorCount * SECTOR_BYTES - 4) {
                throw new IOException("invalid record length " + length);
            }

            byte[] compressed = new byte[length - 1];
            region.readFully(compressed);
            InputStream input = new ByteArrayInputStream(compressed);
            if (compression == 1) input = new GZIPInputStream(input);
            else if (compression == 2) input = new InflaterInputStream(input);
            else if (compression != 3) throw new IOException("unsupported compression " + compression);
            return input.readAllBytes();
        }
    }
}
