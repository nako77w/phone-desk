package io.phonedesk.companion;
import android.accessibilityservice.*;
import android.graphics.Path;
import android.view.accessibility.AccessibilityEvent;

public final class TouchService extends AccessibilityService {
    static volatile TouchService current;
    @Override protected void onServiceConnected() { current = this; }
    @Override public void onAccessibilityEvent(AccessibilityEvent event) {}
    @Override public void onInterrupt() {}
    @Override public void onDestroy() { if (current == this) current = null; super.onDestroy(); }
    void gesture(float x1,float y1,float x2,float y2,int duration) {
        Path path = new Path();
        path.moveTo(x1,y1);
        if (x1 != x2 || y1 != y2) path.lineTo(x2,y2);
        dispatchGesture(new GestureDescription.Builder().addStroke(
            new GestureDescription.StrokeDescription(path,0,duration)).build(),null,null);
    }
}