package io.phonedesk.companion;

import android.Manifest;
import android.app.Activity;
import android.bluetooth.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.media.projection.MediaProjectionManager;
import android.os.*;
import android.provider.Settings;
import android.view.View;
import android.widget.*;
import java.util.*;

public final class MainActivity extends Activity {
    private final ArrayList<BluetoothDevice> devices = new ArrayList<>();
    private Spinner picker;
    private TextView status;
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        LinearLayout content = new LinearLayout(this);
        content.setOrientation(LinearLayout.VERTICAL);
        int margin = (int)(24 * getResources().getDisplayMetrics().density);
        content.setPadding(margin, margin * 2, margin, margin);
        content.setBackgroundColor(Color.rgb(245,248,252));
        ScrollView scroll = new ScrollView(this);
        scroll.addView(content);
        setContentView(scroll);
        TextView title = new TextView(this);
        title.setText("Точка связи");
        title.setTextSize(32);
        content.addView(title);
        TextView description = new TextView(this);
        description.setText("Сопрягите телефон и ноутбук в настройках Bluetooth. Выберите ноутбук и разрешите показ всего экрана.");
        description.setTextSize(16);
        description.setPadding(0,margin/2,0,margin);
        content.addView(description);
        picker = new Spinner(this);
        content.addView(picker);
        button(content,"Обновить список устройств",v -> refresh());
        button(content,"Разрешить управление касаниями",v -> startActivity(new Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)));
        button(content,"Начать трансляцию",v -> begin());
        button(content,"Остановить трансляцию",v -> {
            stopService(new Intent(this,ScreenService.class));
            status.setText("Трансляция остановлена.");
        });
        status = new TextView(this);
        status.setPadding(0,margin/2,0,0);
        content.addView(status);
        refresh();
    }
    private void button(LinearLayout parent, String label, View.OnClickListener action) {
        Button button = new Button(this);
        button.setText(label);
        button.setOnClickListener(action);
        parent.addView(button);
    }
    private boolean allowed() {
        if (Build.VERSION.SDK_INT < 31 || checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED) return true;
        requestPermissions(new String[]{Manifest.permission.BLUETOOTH_CONNECT},1);
        return false;
    }
    private void refresh() {
        if (!allowed()) return;
        BluetoothAdapter adapter = getSystemService(BluetoothManager.class).getAdapter();
        devices.clear();
        ArrayList<String> names = new ArrayList<>();
        if (adapter != null && adapter.isEnabled()) {
            devices.addAll(adapter.getBondedDevices());
            for (BluetoothDevice device : devices) names.add((device.getName() == null ? "Устройство" : device.getName()) + " · " + device.getAddress());
        }
        picker.setAdapter(new ArrayAdapter<>(this,android.R.layout.simple_spinner_dropdown_item,names));
        status.setText(devices.isEmpty() ? "Включите Bluetooth и сначала выполните сопряжение с ноутбуком." : "Выберите ноутбук.");
    }
    @Override public void onRequestPermissionsResult(int code, String[] permissions, int[] result) {
        super.onRequestPermissionsResult(code,permissions,result);
        if (code == 1 && result.length > 0 && result[0] == PackageManager.PERMISSION_GRANTED) refresh();
    }
    private String selectedPeer;
    private void begin() {
        int position = picker.getSelectedItemPosition();
        if (!allowed() || position < 0 || position >= devices.size()) return;
        selectedPeer = devices.get(position).getAddress();
        stopService(new Intent(this,ScreenService.class));
        startActivityForResult(getSystemService(MediaProjectionManager.class).createScreenCaptureIntent(),2);
    }
    @Override protected void onActivityResult(int request,int result,Intent data) {
        super.onActivityResult(request,result,data);
        if (request != 2 || result != RESULT_OK || data == null || selectedPeer == null) return;
        Intent intent = new Intent(this,ScreenService.class).putExtra("consent",data).putExtra("peer",selectedPeer);
        startForegroundService(intent);
        status.setText("Откройте окно Bluetooth в «Точке связи» на ноутбуке и подключите его COM‑порт.");
    }
    @Override protected void onSaveInstanceState(Bundle state) {
        super.onSaveInstanceState(state);
        state.putString("peer",selectedPeer);
    }
    @Override protected void onRestoreInstanceState(Bundle state) {
        super.onRestoreInstanceState(state);
        selectedPeer = state.getString("peer");
    }
}