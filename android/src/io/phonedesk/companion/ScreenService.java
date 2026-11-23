package io.phonedesk.companion;

import android.app.*;
import android.bluetooth.*;
import android.content.Intent;
import android.graphics.*;
import android.hardware.display.*;
import android.media.*;
import android.media.projection.*;
import android.os.*;
import android.util.DisplayMetrics;
import android.view.*;
import android.widget.Toast;
import java.io.*;
import java.nio.ByteBuffer;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public final class ScreenService extends Service {
    private static final UUID SERIAL = UUID.fromString("00001101-0000-1000-8000-00805f9b34fb");
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService writer = Executors.newSingleThreadExecutor();
    private volatile BluetoothServerSocket server;
    private volatile BluetoothSocket peer;
    private volatile DataOutputStream output;
    private boolean writing;
    private MediaProjection projection;
    private VirtualDisplay display;
    private ImageReader reader;
    private int width, height;
    private long lastFrame;
    private volatile boolean stopped;
    private Thread acceptThread;

    @Override public IBinder onBind(Intent intent) { return null; }

    @Override public int onStartCommand(Intent intent,int flags,int id) {
        if (intent == null || projection != null) return START_NOT_STICKY;
        NotificationManager manager = getSystemService(NotificationManager.class);
        manager.createNotificationChannel(new NotificationChannel("screen","Трансляция экрана",NotificationManager.IMPORTANCE_LOW));
        PendingIntent open = PendingIntent.getActivity(this,0,new Intent(this,MainActivity.class),PendingIntent.FLAG_IMMUTABLE);
        startForeground(4,new Notification.Builder(this,"screen").setContentTitle("Точка связи")
            .setContentText("Экран может передаваться на выбранный ноутбук").setSmallIcon(android.R.drawable.ic_menu_view)
            .setContentIntent(open).setOngoing(true).build());
        try {
            Intent consent = intent.getParcelableExtra("consent");
            String allowedPeer = intent.getStringExtra("peer");
            if (consent == null || allowedPeer == null) throw new IllegalArgumentException();
            projection = getSystemService(MediaProjectionManager.class).getMediaProjection(Activity.RESULT_OK,consent);
            projection.registerCallback(new MediaProjection.Callback() {
                @Override public void onStop() { stopSelf(); }
                @Override public void onCapturedContentResize(int w,int h) {
                    if (display != null) resize(w,h);
                }
            },main);
            DisplayMetrics metrics = metrics();
            resize(metrics.widthPixels,metrics.heightPixels);
            acceptThread = new Thread(() -> accept(allowedPeer),"PhoneDesk RFCOMM");
            acceptThread.start();
        } catch (RuntimeException error) {
            Toast.makeText(this,"Не удалось начать захват экрана.",Toast.LENGTH_LONG).show();
            stopSelf();
        }
        return START_NOT_STICKY;
    }

    private DisplayMetrics metrics() {
        DisplayMetrics metrics = new DisplayMetrics();
        getSystemService(WindowManager.class).getDefaultDisplay().getRealMetrics(metrics);
        return metrics;
    }

    private void resize(int w,int h) {
        if (stopped || w <= 0 || h <= 0) return;
        double scale = Math.min(1.0,384.0/Math.max(w,h));
        int nextWidth = Math.max(1,(int)(w*scale));
        int nextHeight = Math.max(1,(int)(h*scale));
        if (nextWidth == width && nextHeight == height) return;
        width = nextWidth;
        height = nextHeight;
        ImageReader next = ImageReader.newInstance(width,height,PixelFormat.RGBA_8888,2);
        next.setOnImageAvailableListener(this::frame,main);
        int dpi = getResources().getDisplayMetrics().densityDpi;
        if (display == null) display = projection.createVirtualDisplay("PhoneDesk",width,height,dpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,next.getSurface(),null,main);
        else {
            display.setSurface(null);
            display.resize(width,height,dpi);
            display.setSurface(next.getSurface());
        }
        if (reader != null) reader.close();
        reader = next;
    }

    private void accept(String allowedPeer) {
        try {
            BluetoothAdapter adapter = getSystemService(BluetoothManager.class).getAdapter();
            try (BluetoothServerSocket socket = adapter.listenUsingRfcommWithServiceRecord("PhoneDesk",SERIAL)) {
                server = socket;
                while (!stopped) {
                    try (BluetoothSocket client = socket.accept()) {
                        if (!allowedPeer.equalsIgnoreCase(client.getRemoteDevice().getAddress())) continue;
                        peer = client;
                        DataOutputStream stream = new DataOutputStream(new BufferedOutputStream(client.getOutputStream()));
                        stream.writeInt(0x50484431);
                        stream.flush();
                        output = stream;
                        readGestures(new DataInputStream(client.getInputStream()));
                    } catch (IOException ignored) {
                        if (stopped) break;
                    } finally { output = null; peer = null; }
                }
            }
        } catch (IOException | RuntimeException error) {
            if (!stopped) main.post(() -> {
                Toast.makeText(this,"Не удалось открыть Bluetooth‑канал.",Toast.LENGTH_LONG).show();
                stopSelf();
            });
        } finally { server = null; }
    }

    private void readGestures(DataInputStream stream) throws IOException {
        while (!stopped) {
            if (stream.readUnsignedByte() != 1) throw new IOException("Unknown command");
            int x1 = stream.readUnsignedShort(), y1 = stream.readUnsignedShort();
            int x2 = stream.readUnsignedShort(), y2 = stream.readUnsignedShort();
            int duration = stream.readUnsignedShort();
            if (x1 > 10000 || y1 > 10000 || x2 > 10000 || y2 > 10000 || duration < 30 || duration > 1000) continue;
            long received = SystemClock.elapsedRealtime();
            main.post(() -> {
                TouchService control = TouchService.current;
                if (stopped || output == null || control == null || SystemClock.elapsedRealtime()-received > 500) return;
                DisplayMetrics metrics = metrics();
                if ((metrics.widthPixels > metrics.heightPixels) != (width > height)) return;
                control.gesture(x1*(metrics.widthPixels-1)/10000f,y1*(metrics.heightPixels-1)/10000f,
                    x2*(metrics.widthPixels-1)/10000f,y2*(metrics.heightPixels-1)/10000f,duration);
            });
        }
    }

    private void frame(ImageReader source) {
        if (stopped || source != reader) return;
        try (Image image = source.acquireLatestImage()) {
            if (image == null) return;
            if (Build.VERSION.SDK_INT < 34) {
                DisplayMetrics m = metrics();
                if ((m.widthPixels > m.heightPixels) != (width > height)) {
                    main.post(() -> resize(m.widthPixels,m.heightPixels));
                    return;
                }
            }
            DataOutputStream stream = output;
            long now = SystemClock.elapsedRealtime();
            if (stream == null || writing || now-lastFrame < 180) return;
            lastFrame = now;
            int imageWidth = image.getWidth(), imageHeight = image.getHeight();
            Image.Plane plane = image.getPlanes()[0];
            int stride = plane.getRowStride(), pixels = plane.getPixelStride();
            ByteBuffer input = plane.getBuffer();
            int[] colors = new int[imageWidth*imageHeight];
            for (int y=0; y<imageHeight; y++) {
                for (int x=0; x<imageWidth; x++) {
                    int offset=y*stride+x*pixels;
                    colors[y*imageWidth+x]=0xff000000 | ((input.get(offset)&255)<<16)
                        | ((input.get(offset+1)&255)<<8) | (input.get(offset+2)&255);
                }
            }
            Bitmap bitmap = Bitmap.createBitmap(colors,imageWidth,imageHeight,Bitmap.Config.ARGB_8888);
            writing = true;
            writer.execute(() -> writeFrame(stream,bitmap));
        } catch (IllegalStateException ignored) {}
    }

    private void writeFrame(DataOutputStream stream,Bitmap bitmap) {
        try {
            ByteArrayOutputStream frame = new ByteArrayOutputStream();
            if (bitmap.compress(Bitmap.CompressFormat.JPEG,45,frame)) {
                stream.writeInt(frame.size());
                frame.writeTo(stream);
                stream.flush();
            }
        } catch (IOException ignored) {
        } finally {
            bitmap.recycle();
            main.post(() -> writing=false);
        }
    }

    @Override public void onDestroy() {
        stopped = true;
        output = null;
        if (server != null) try { server.close(); } catch (IOException ignored) {}
        if (peer != null) try { peer.close(); } catch (IOException ignored) {}
        if (display != null) display.release();
        if (reader != null) reader.close();
        if (projection != null) projection.stop();
        writer.shutdown();
        super.onDestroy();
    }
}