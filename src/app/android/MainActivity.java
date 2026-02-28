package com.kapricornmedia.zigkm;

import java.io.BufferedInputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.file.Files;
import java.lang.Runnable;
import java.lang.Thread;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;

import android.app.DownloadManager;
import android.app.NativeActivity;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ActivityInfo;
import android.database.Cursor;
import android.graphics.Rect;
import android.net.Uri;
import android.os.Bundle;
import android.os.Environment;
import android.util.Log;
import android.view.inputmethod.InputMethodManager;
import android.view.KeyEvent;
import android.view.View;
import android.view.Window;
import android.view.WindowInsetsController;
import androidx.core.content.FileProvider;

public class MainActivity extends NativeActivity
{
    public static final String LOG_TAG = "com.kapricornmedia.zigkm";

    private native void onKeyInput(int action, int keyCode, int codePoint);
    private native void onHttp(int method, String url, int code, byte[] data);
    private native void onAppLink(String url);
    private native void onDownloadFile(String url, String fileName, boolean success);

    static {
        // Redundant with the other implicit loading of the library, but I've at least verified
        // that they play nicely with each other (e.g. global variables are the same).
        // Without this, the native function doesn't link. I think the other load is more specific.
        System.loadLibrary("applib");
    }

    public String fullPath(String file)
    {
        return getApplicationContext().getFilesDir().getAbsolutePath() + "/" + file;
    }

    public void showKeyboard(boolean show)
    {
        View view = getWindow().getDecorView();
        InputMethodManager inputMethodManager = (InputMethodManager)getSystemService(Context.INPUT_METHOD_SERVICE);
        if (inputMethodManager == null) {
            Log.e(LOG_TAG, "Failed to get input method manager");
            return;
        }
        if (show) {
            if (!inputMethodManager.showSoftInput(view, 0)) {
                Log.e(LOG_TAG, "showSoftInput failed");
            }
        } else {
            inputMethodManager.hideSoftInputFromWindow(view.getWindowToken(), 0);
        }
    }

    // method: GET = 0, POST = 1
    public void httpRequest(int method, String url, String h1, String v1, byte[] body)
    {
        Thread thread = new Thread(new Runnable() {
            public void run()
            {
                HttpURLConnection urlConnection;
                try {
                    URL urlObj = new URL(url);
                    urlConnection = (HttpURLConnection)urlObj.openConnection();
                    urlConnection.setConnectTimeout(10000);
                    urlConnection.setReadTimeout(10000);
                    if (h1.length() > 0) {
                        urlConnection.setRequestProperty(h1, v1);
                    }

                    if (method == 0) {
                        urlConnection.setRequestMethod("GET");
                    } else if (method == 1) {
                        urlConnection.setRequestMethod("POST");
                        urlConnection.setDoOutput(true);

                        OutputStream os = urlConnection.getOutputStream();
                        os.write(body);
                        os.flush();
                        os.close();
                    } else {
                        onHttp(method, url, 0, new byte[0]);
                        return;
                    }
                } catch (Exception e) {
                    Log.e(LOG_TAG, "Exception1 method=" + e.toString() + " url=" + url + " e=" + e.toString());
                    onHttp(method, url, 0, new byte[0]);
                    return;
                }
                try {
                    int code = urlConnection.getResponseCode();
                    InputStream in;
                    if (code == 200) {
                        in = new BufferedInputStream(urlConnection.getInputStream());
                    } else {
                        in = new BufferedInputStream(urlConnection.getErrorStream());
                    }
                    ByteArrayOutputStream buffer = new ByteArrayOutputStream();
                    int i = in.read();
                    while (i != -1) {
                        buffer.write(i);
                        i = in.read();
                    }
                    onHttp(method, url, code, buffer.toByteArray());
                } catch (Exception e) {
                    Log.e(LOG_TAG, "Exception2 method=" + e.toString() + " url=" + url + " e=" + e.toString());
                    onHttp(method, url, 0, new byte[0]);
                } finally {
                    urlConnection.disconnect();
                }
            }
        });
        thread.start();
    }

    public int getStatusBarHeight()
    {
        Rect rectangle = new Rect();
        Window window = getWindow();
        window.getDecorView().getWindowVisibleDisplayFrame(rectangle);
        int statusBarHeight = rectangle.top;
        int contentViewTop = window.findViewById(Window.ID_ANDROID_CONTENT).getTop();
        return Math.abs(contentViewTop - statusBarHeight);
    }

    public boolean writePrivateFile(String fileName, byte[] data)
    {
        String fullPath = getApplicationContext().getExternalFilesDir(null) + "/" + fileName;
        try {
            File file = new File(fullPath);
            FileOutputStream writer = new FileOutputStream(file);
            writer.write(data);
            writer.flush();
            writer.close();
        } catch (Exception e){
            e.printStackTrace();
            return false;
        }
        return true;
    }

    public byte[] readPrivateFile(String fileName)
    {
        String fullPath = getApplicationContext().getExternalFilesDir(null) + "/" + fileName;
        try {
            File file = new File(fullPath);
            return Files.readAllBytes(file.toPath());
        } catch (Exception e){
            e.printStackTrace();
        }
        return new byte[0];
    }

    public void downloadAndOpenFile(String url, String filePath, String title, String h1, String v1)
    {
        Thread thread = new Thread(new Runnable() {
            public void run()
            {
                String path = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS) + "/" + filePath;
                File file = new File(path);
                boolean success = true;
                if (!file.isFile()) {
                    DownloadManager manager = (DownloadManager)getSystemService(Context.DOWNLOAD_SERVICE);
                    DownloadManager.Request request = new DownloadManager.Request(Uri.parse(url));
                    request.setTitle(title);
                    request.addRequestHeader(h1, v1);
                    request.setDestinationUri(Uri.parse("file://" + path));
                    request.setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED);

                    long refId = manager.enqueue(request);
                    DownloadManager.Query q = new DownloadManager.Query().setFilterById(refId);
                    boolean done = false;
                    while (!done) {
                        Cursor c = manager.query(q);
                        if (!c.moveToFirst()) continue;
                        do {
                            int colStatusIndex = c.getColumnIndex(DownloadManager.COLUMN_STATUS);
                            if (c.isNull(colStatusIndex)) continue;
                            int status = c.getInt(colStatusIndex);
                            if (status == DownloadManager.STATUS_SUCCESSFUL) {
                                done = true;
                                break;
                            } else if (status == DownloadManager.STATUS_FAILED) {
                                done = true;
                                success = false;
                                break;
                            }
                        } while (c.moveToNext());
                        try {
                            Thread.sleep(100);
                        } catch (Exception e) {
                        }
                    }
                }

                if (success) {
                    Uri myUri = FileProvider.getUriForFile(getApplicationContext(), getApplicationContext().getPackageName() + ".provider", file);
                    Intent target = new Intent(Intent.ACTION_VIEW);
                    target.setDataAndType(myUri, "application/pdf");
                    target.addFlags(Intent.FLAG_ACTIVITY_NO_HISTORY);
                    target.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                    Intent intent = Intent.createChooser(target, "Open File");
                    try {
                        startActivity(intent);
                    } catch (Exception e) {
                        Log.e(LOG_TAG, "startActivity failed " + e.toString());
                    }
                }

                onDownloadFile(url, filePath, success);
            }
        });
        thread.start();
    }

    @Override
    protected void onCreate(Bundle savedInstanceState)
    {
        super.onCreate(savedInstanceState);

        setRequestedOrientation(ActivityInfo.SCREEN_ORIENTATION_NOSENSOR);
    }

    @Override
    protected void onStart()
    {
        super.onStart();

        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
            getWindow().getInsetsController().setSystemBarsAppearance(WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS, WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS);
        }

        Intent intent = getIntent();
        Uri url = intent.getData();
        if (url != null) {
            String urlString = url.toString();
            onAppLink(urlString);
        }
    }

    @Override
    public boolean dispatchKeyEvent(KeyEvent event)
    {
        final int action = event.getAction();
        if (action == KeyEvent.ACTION_MULTIPLE) {
            final String str = event.getCharacters();
            int i = 0;
            while (i < str.length()) {
                final int codePoint = str.codePointAt(i);
                onKeyInput(KeyEvent.ACTION_DOWN, 0, codePoint);
                i += Character.charCount(codePoint);
            }
        }
        else {
            final int keyCode = event.getKeyCode();
            final int codePoint = event.getUnicodeChar();
            onKeyInput(action, keyCode, codePoint);
        }
        return true;
    }
}
