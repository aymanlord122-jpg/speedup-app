import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

const cf = 'https://speed.cloudflare.com';
const bg = Color(0xFF0B1220), card = Color(0xFF131C31), line = Color(0xFF22304F);
const blue = Color(0xFF38BDF8), green = Color(0xFF34D399), red = Color(0xFFF87171), muted = Color(0xFF8EA0C6);

/* ---------------- البينغ (TCP) — يعمل على أندرويد وآيفون ---------------- */
Future<double?> tcpPing(String host, int port, {int timeoutMs = 2500}) async {
  final sw = Stopwatch()..start();
  try {
    final s = await Socket.connect(host, port, timeout: Duration(milliseconds: timeoutMs));
    sw.stop();
    s.destroy();
    return sw.elapsedMicroseconds / 1000.0;
  } catch (_) {
    return null;
  }
}

/// سيرفرات الفحص. ضع هنا سيرفرات LibreSpeed داخل سوريا (الرابط = المجلد الذي فيه garbage.php و empty.php و getIP.php)
class Srv {
  final String name, base, type; // type: 'ls' = LibreSpeed (محلي) ، 'cf' = Cloudflare (خارجي)
  final bool local;
  const Srv(this.name, this.base, this.type, this.local);
  Uri get uri => Uri.parse(base);
  String get host => uri.host;
  int get port => uri.hasPort ? uri.port : (uri.scheme == 'http' ? 80 : 443);
  String get root => base.endsWith('/') ? base.substring(0, base.length - 1) : base;
  String downUrl(int r) => type == 'cf' ? '$root/__down?bytes=25000000&r=$r' : '$root/garbage.php?ckSize=100&r=$r';
  String upUrl(int r) => type == 'cf' ? '$root/__up?r=$r' : '$root/empty.php?r=$r';
}

const servers = <Srv>[
  Srv('سيرفر محلي (عدّل الرابط)', 'https://speedtest.example.sy/backend/', 'ls', true),
  Srv('Cloudflare', 'https://speed.cloudflare.com', 'cf', false),
];
Srv? gSrv;

Future<double?> pingServer() {
  final s = gSrv;
  return s == null ? tcpPing('1.1.1.1', 443) : tcpPing(s.host, s.port);
}

Future<double?> pingGoogle() => tcpPing('8.8.8.8', 53);

/// يختار أقرب سيرفر محلي متاح، وإن لم يوجد فأقرب سيرفر عموماً
Future<Srv?> pickServer([Srv? forced]) async {
  if (forced != null) {
    gSrv = forced;
    return gSrv;
  }
  final res = await Future.wait(servers.map((s) async {
    final v = <double>[];
    await tcpPing(s.host, s.port, timeoutMs: 2000);
    for (var i = 0; i < 3; i++) {
      final x = await tcpPing(s.host, s.port, timeoutMs: 2000);
      if (x != null) v.add(x);
    }
    if (v.isEmpty) return null;
    v.sort();
    return v[v.length ~/ 2];
  }));
  int best = -1, bestL = -1;
  for (var i = 0; i < servers.length; i++) {
    final ms = res[i];
    if (ms == null) continue;
    if (best < 0 || ms < res[best]!) best = i;
    if (servers[i].local && (bestL < 0 || ms < res[bestL]!)) bestL = i;
  }
  gSrv = servers[bestL >= 0 ? bestL : (best >= 0 ? best : servers.length - 1)];
  return gSrv;
}

/* ---------------- خدمة الخلفية ---------------- */
@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  final fln = FlutterLocalNotificationsPlugin();
  await fln.initialize(const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher')));

  bool stopped = false, down = false;
  String host = '1.1.1.1';
  int port = 443;
  DateTime? downAt;
  final log = <Map<String, dynamic>>[];

  service.on('stop').listen((_) {
    stopped = true;
    service.stopSelf();
  });
  service.on('sync').listen((_) => service.invoke('log', {'items': log}));
  service.on('cfg').listen((e) {
    host = (e?['host'] ?? host).toString();
    port = (e?['port'] as num?)?.toInt() ?? port;
  });
  service.invoke('ready');

  while (!stopped) {
    final t0 = DateTime.now();
    final r = await Future.wait([tcpPing(host, port), pingGoogle()]);
    final a = r[0], g = r[1];
    final isDown = a == null && g == null;

    if (isDown && !down) {
      down = true;
      downAt = DateTime.now();
      log.insert(0, {'type': 'down', 'ts': downAt.millisecondsSinceEpoch});
      await fln.show(
          999, 'انقطع الإنترنت', 'تم فقد الاتصال',
          const NotificationDetails(
              android: AndroidNotificationDetails('alerts', 'تنبيهات الانقطاع',
                  importance: Importance.max, priority: Priority.high)));
      service.invoke('log', {'items': log});
    } else if (!isDown && down) {
      down = false;
      final d = DateTime.now().difference(downAt!).inSeconds;
      log.insert(0, {'type': 'up', 'ts': DateTime.now().millisecondsSinceEpoch, 'dur': d});
      service.invoke('log', {'items': log});
    }

    service.invoke('tick', {'a': a, 'g': g});
    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
        title: isDown ? 'الإنترنت مفصول!' : 'الإنترنت يعمل',
        content: a == null ? 'بدون استجابة' : 'بينغ: ${a.round()} ms',
      );
    }
    final wait = 1000 - DateTime.now().difference(t0).inMilliseconds;
    if (wait > 0) await Future.delayed(Duration(milliseconds: wait));
  }
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async => true;

Future<void> initService() async {
  final fln = FlutterLocalNotificationsPlugin();
  final android = fln.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
  await android?.createNotificationChannel(const AndroidNotificationChannel(
      'monitor', 'SpeedUp', importance: Importance.low));
  await android?.requestNotificationsPermission();

  await FlutterBackgroundService().configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: false,
      isForegroundMode: true,
      notificationChannelId: 'monitor',
      initialNotificationTitle: 'SpeedUp',
      initialNotificationContent: 'جارٍ التشغيل...',
      foregroundServiceNotificationId: 888,
      foregroundServiceTypes: [AndroidForegroundType.dataSync],
    ),
    iosConfiguration: IosConfiguration(
        autoStart: false, onForeground: onStart, onBackground: onIosBackground),
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initService();
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'SpeedUp',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark().copyWith(scaffoldBackgroundColor: bg),
        builder: (c, child) => Directionality(textDirection: TextDirection.rtl, child: child!),
        home: const Home(),
      );
}

class Home extends StatelessWidget {
  const Home({super.key});
  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 2,
        child: Scaffold(
          appBar: AppBar(
            backgroundColor: bg,
            title: const Text('SpeedUp'),
            centerTitle: true,
            bottom: const TabBar(tabs: [Tab(text: 'فحص السرعة'), Tab(text: 'مراقبة الصيانة')]),
          ),
          body: Stack(children: [
            const Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: EarthPainter()))),
            const TabBarView(children: [SpeedPage(), MonitorPage()]),
          ]),
        ),
      );
}

Widget box(Widget child) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
        color: const Color(0xC7131C31), borderRadius: BorderRadius.circular(14), border: Border.all(color: line)),
    child: child);

Widget metric(String label, String v, String unit) => Expanded(
    child: Container(
        margin: const EdgeInsets.all(4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: const Color(0xB80E1628), borderRadius: BorderRadius.circular(12)),
        child: Column(children: [
          Text(label, style: const TextStyle(color: muted, fontSize: 12)),
          const SizedBox(height: 4),
          Text(v, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
          Text(unit, style: const TextStyle(color: muted, fontSize: 12)),
        ])));

/* ---------------- صفحة فحص السرعة ---------------- */
class SpeedPage extends StatefulWidget {
  const SpeedPage({super.key});
  @override
  State<SpeedPage> createState() => _SpeedPageState();
}

class _SpeedPageState extends State<SpeedPage> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  String server = '...', ip = '...', isp = '...', localIp = '...';
  String warn = '';
  String phase = 'جاهز', live = '0', dl = '--', ul = '--', pg = '--', gg = '--', jt = '--', ls = '--';
  double prog = 0;
  bool running = false;

  @override
  void initState() {
    super.initState();
    loadInfo();
  }

  Future<void> loadInfo() async {
    try {
      localIp = await NetworkInfo().getWifiIP() ?? 'غير متصل بشبكة Wi-Fi (بيانات الجوال)';
    } catch (_) {
      localIp = 'غير متاح';
    }
    try {
      final s = gSrv ?? await pickServer();
      if (s == null) {
        server = 'لا يوجد سيرفر متاح';
      } else {
        final c = HttpClient()..connectionTimeout = const Duration(seconds: 4);
        if (s.type == 'cf') {
          final r = await (await c.getUrl(Uri.parse('${s.root}/meta'))).close();
          final m = jsonDecode(await r.transform(utf8.decoder).join());
          final colo = m['colo'] is Map ? m['colo'] as Map : {'iata': m['colo']};
          final city = (colo['city'] ?? colo['iata'] ?? '?').toString();
          final iata = colo['iata'] == null || colo['city'] == null ? '' : ' (${colo['iata']})';
          server = 'Cloudflare — $city$iata · خارجي';
          ip = m['clientIp'] ?? '--';
          isp = m['asOrganization'] ?? '--';
        } else {
          server = '${s.name} · محلي';
          final r = await (await c.getUrl(Uri.parse('${s.root}/getIP.php?isp=true'))).close();
          final m = jsonDecode(await r.transform(utf8.decoder).join());
          final parts = (m['processedString'] ?? '').toString().split(' - ');
          ip = parts.first.isEmpty ? '--' : parts.first;
          isp = parts.length > 1 ? parts.sublist(1).join(' - ') : '--';
        }
        warn = s.local ? '' : 'لا يوجد سيرفر محلي متاح، النتيجة عبر الإنترنت الدولي وقد تختلف عن الواقع المحلي.';
        c.close();
      }
    } catch (_) {
      server = 'تعذر الحصول على المعلومات';
    }
    if (mounted) setState(() {});
  }

  void set(VoidCallback f) {
    if (mounted) setState(f);
  }

  Future<void> start() async {
    set(() {
      running = true;
      dl = ul = pg = gg = jt = ls = '--';
    });
    gSrv = null; // إعادة اختيار أقرب سيرفر محلي
    await loadInfo();
    try {
      await testPing();
      dl = (await transfer(true)).toStringAsFixed(1);
      ul = (await transfer(false)).toStringAsFixed(1);
      set(() {
        phase = 'اكتمل الفحص';
        live = '✓';
      });
    } catch (_) {
      set(() => phase = 'حدث خطأ');
    }
    set(() {
      running = false;
      prog = 0;
    });
  }

  Future<void> testPing() async {
    set(() {
      phase = 'قياس البينغ...';
      live = '…';
    });
    await pingServer();
    final a = <double>[], g = <double>[];
    int lost = 0;
    const n = 12;
    for (var i = 0; i < n; i++) {
      final x = await pingServer();
      x == null ? lost++ : a.add(x);
      final y = await pingGoogle();
      if (y != null) g.add(y);
      set(() => prog = (i + 1) / n);
      await Future.delayed(const Duration(milliseconds: 120));
    }
    set(() {
      if (a.isNotEmpty) {
        pg = (([...a]..sort())[a.length ~/ 2]).round().toString();
        double s = 0;
        for (var i = 1; i < a.length; i++) {
          s += (a[i] - a[i - 1]).abs();
        }
        jt = (s / max(1, a.length - 1)).toStringAsFixed(1);
      }
      if (g.isNotEmpty) gg = (g.reduce((x, y) => x + y) / g.length).round().toString();
      ls = (lost / n * 100).round().toString();
    });
  }

  /// تحميل أو رفع بعدة اتصالات متوازية. يرجع Mbps
  Future<double> transfer(bool download) async {
    set(() => phase = download ? 'قياس التحميل...' : 'قياس الرفع...');
    final dur = download ? 12000 : 10000;
    const warm = 2000, streams = 6;
    final srv = gSrv ?? servers.last;
    final sw = Stopwatch()..start();
    int bytes = 0, b0 = 0, t0 = -1;
    final clients = <HttpClient>[];
    final chunk = Uint8List(65536);
    final rnd = Random();
    for (var i = 0; i < chunk.length; i++) {
      chunk[i] = rnd.nextInt(256);
    }

    Future<void> worker() async {
      final c = HttpClient();
      clients.add(c);
      while (sw.elapsedMilliseconds < dur) {
        try {
          if (download) {
            final req = await c.getUrl(Uri.parse(srv.downUrl(rnd.nextInt(1 << 30))));
            final res = await req.close();
            await for (final d in res) {
              bytes += d.length;
              if (sw.elapsedMilliseconds >= dur) break;
            }
          } else {
            final req = await c.postUrl(Uri.parse(srv.upUrl(rnd.nextInt(1 << 30))));
            req.headers.contentType = ContentType.binary;
            req.contentLength = chunk.length * 64;
            for (var i = 0; i < 64; i++) {
              req.add(chunk);
              await req.flush();
              bytes += chunk.length;
              if (sw.elapsedMilliseconds >= dur) break;
            }
            if (sw.elapsedMilliseconds >= dur) break;
            final res = await req.close();
            await res.drain();
          }
        } catch (_) {
          break;
        }
      }
      c.close(force: true);
    }

    final timer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      final el = sw.elapsedMilliseconds;
      if (t0 < 0 && el >= warm) {
        t0 = el;
        b0 = bytes;
      }
      if (t0 >= 0 && el > t0) {
        set(() => live = ((bytes - b0) * 8 / ((el - t0) / 1000) / 1e6).toStringAsFixed(1));
      }
      set(() => prog = min(1.0, el / dur));
    });
    await Future.wait(List.generate(streams, (_) => worker()));
    timer.cancel();
    for (final c in clients) {
      c.close(force: true);
    }
    final el = sw.elapsedMilliseconds;
    final mbps = t0 >= 0 ? (bytes - b0) * 8 / ((el - t0) / 1000) / 1e6 : bytes * 8 / (el / 1000) / 1e6;
    set(() => live = mbps.toStringAsFixed(1));
    return mbps;
  }

  Widget infoRow(String k, String v) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(k, style: const TextStyle(color: muted)),
        const SizedBox(width: 12),
        Expanded(child: Text(v, textDirection: TextDirection.ltr, textAlign: TextAlign.left)),
      ]));

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ListView(padding: const EdgeInsets.all(14), children: [
      box(Column(children: [
        Text(phase, style: const TextStyle(color: muted)),
        Gauge(
            frac: speedFrac(double.tryParse(live) ?? 0),
            text: live,
            unit: 'Mbps',
            color: phase.contains('الرفع') ? green : blue,
            ticks: speedTicks,
            fracOf: speedFrac),
        const SizedBox(height: 2),
        SizedBox(
          height: 52,
          child: FilledButton(
              onPressed: running ? null : start,
              child: Text(running ? 'جارٍ الفحص...' : 'ابدأ الفحص', style: const TextStyle(fontSize: 16)))),
        const SizedBox(height: 10),
        LinearProgressIndicator(value: prog, color: blue, backgroundColor: const Color(0xFF0E1628)),
      ])),
      box(Column(children: [
        Row(children: [metric('التحميل', dl, 'Mbps'), metric('الرفع', ul, 'Mbps')]),
        Row(children: [metric('البينغ', pg, 'ms'), metric('بينغ دولي (Google)', gg, 'ms')]),
        Row(children: [metric('Jitter', jt, 'ms'), metric('فقد الحزم', ls, '%')]),
      ])),
      box(Column(children: [
        infoRow('السيرفر', server),
        infoRow('IP العام', ip),
        infoRow('مزود الخدمة', isp),
        infoRow('IP الجهاز', localIp),
        if (warn.isNotEmpty)
          Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(warn, style: const TextStyle(color: Color(0xFFFBBF24), fontSize: 12))),
      ])),
    ]);
  }
}

/* ---------------- صفحة المراقبة (تعمل بالخلفية) ---------------- */
class MonitorPage extends StatefulWidget {
  const MonitorPage({super.key});
  @override
  State<MonitorPage> createState() => _MonitorPageState();
}

class _MonitorPageState extends State<MonitorPage> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  static const maxPts = 120;
  final sa = <double?>[], sg = <double?>[];
  List<Map> items = [];
  bool on = false;
  int total = 0, lost = 0, cnt = 0;
  double mn = 1e9, mx = 0, sum = 0;
  StreamSubscription? s1, s2;

  @override
  void initState() {
    super.initState();
    FlutterBackgroundService().isRunning().then((r) {
      if (r) attach();
    });
  }

  void attach() {
    final svc = FlutterBackgroundService();
    on = true;
    s1?.cancel();
    s2?.cancel();
    s1 = svc.on('tick').listen((e) {
      final a = (e?['a'] as num?)?.toDouble(), g = (e?['g'] as num?)?.toDouble();
      if (!mounted) return;
      setState(() {
        total++;
        if (a == null) lost++;
        if (a != null) {
          mn = min(mn, a);
          mx = max(mx, a);
          sum += a;
          cnt++;
        }
        sa.add(a);
        sg.add(g);
        if (sa.length > maxPts) {
          sa.removeAt(0);
          sg.removeAt(0);
        }
      });
    });
    s2 = svc.on('log').listen((e) {
      if (mounted) setState(() => items = List<Map>.from(e?['items'] ?? []));
    });
    svc.invoke('sync');
  }

  Future<void> toggle() async {
    final svc = FlutterBackgroundService();
    if (on) {
      svc.invoke('stop');
      s1?.cancel();
      s2?.cancel();
      WakelockPlus.disable();
      setState(() => on = false);
    } else {
      final s = gSrv ?? await pickServer();
      await svc.startService();
      WakelockPlus.enable(); // iOS: يبقي الشاشة شغالة لأن iOS يوقف التطبيق بالخلفية
      setState(() {
        sa.clear();
        sg.clear();
        total = lost = cnt = 0;
        mn = 1e9;
        mx = sum = 0;
      });
      attach();
      void sendCfg() => svc.invoke('cfg', {'host': s?.host ?? '1.1.1.1', 'port': s?.port ?? 443});
      svc.on('ready').listen((_) => sendCfg());
      Future.delayed(const Duration(seconds: 1), sendCfg);
    }
  }

  @override
  void dispose() {
    s1?.cancel();
    s2?.cancel();
    super.dispose();
  }

  String t(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String p(int n) => n.toString().padLeft(2, '0');
    return '${p(d.hour)}:${p(d.minute)}:${p(d.second)}';
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final lastA = sa.isNotEmpty ? sa.last : null;
    final lastG = sg.isNotEmpty ? sg.last : null;
    final isDown = on && sa.isNotEmpty && lastA == null && lastG == null;
    return ListView(padding: const EdgeInsets.all(14), children: [
      box(Column(children: [
        Row(children: [
          Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: !on ? muted : (isDown ? red : green),
                  boxShadow: on ? [BoxShadow(color: isDown ? red : green, blurRadius: 10)] : null)),
          const SizedBox(width: 10),
          Text(!on ? 'متوقف' : (isDown ? 'الإنترنت مفصول!' : 'الإنترنت يعمل'),
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
        ]),
        const SizedBox(height: 10),
        Gauge(
            frac: pingFrac(lastA ?? 0),
            text: lastA == null ? (on && sa.isNotEmpty ? '—' : '0') : lastA.round().toString(),
            unit: 'ms',
            color: on ? pingColor(lastA) : muted,
            ticks: pingTicks,
            fracOf: pingFrac),
        Row(children: [
          metric('دولي (Google)', lastG == null ? '--' : lastG.round().toString(), 'ms'),
          metric('متوسط', cnt == 0 ? '--' : (sum / cnt).round().toString(), 'ms'),
        ]),
        Row(children: [
          metric('أعلى', cnt == 0 ? '--' : mx.round().toString(), 'ms'),
          metric('فقد', total == 0 ? '--' : (lost / total * 100).toStringAsFixed(1), '%'),
        ]),
      ])),
      box(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(height: 220, width: double.infinity, child: CustomPaint(painter: ChartPainter(sa, sg, maxPts))),
        const SizedBox(height: 8),
        const Row(children: [
          Icon(Icons.circle, size: 10, color: blue), Text(' السيرفر   ', style: TextStyle(color: muted, fontSize: 12)),
          Icon(Icons.circle, size: 10, color: green), Text(' دولي (Google)   ', style: TextStyle(color: muted, fontSize: 12)),
          Icon(Icons.circle, size: 10, color: red), Text(' انقطاع', style: TextStyle(color: muted, fontSize: 12)),
        ]),
      ])),
      SizedBox(
          height: 52,
          child: FilledButton(
              style: on ? FilledButton.styleFrom(backgroundColor: red) : null,
              onPressed: toggle,
              child: Text(on ? 'إيقاف المراقبة' : 'بدء المراقبة', style: const TextStyle(fontSize: 16)))),
      const SizedBox(height: 12),
      box(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('سجل الانقطاعات', style: TextStyle(fontWeight: FontWeight.bold)),
        if (items.isEmpty) const Padding(padding: EdgeInsets.only(top: 8), child: Text('لا يوجد انقطاعات بعد', style: TextStyle(color: muted))),
        for (final e in items)
          Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Text(e['type'] == 'down' ? 'انقطع الإنترنت' : 'عاد بعد ${e['dur']} ثانية',
                    style: TextStyle(color: e['type'] == 'down' ? red : green)),
                Text(t(e['ts']), style: const TextStyle(color: muted)),
              ])),
      ])),
    ]);
  }
}

class ChartPainter extends CustomPainter {
  final List<double?> a, g;
  final int maxPts;
  ChartPainter(this.a, this.g, this.maxPts);

  @override
  void paint(Canvas c, Size s) {
    c.drawRRect(RRect.fromRectAndRadius(Offset.zero & s, const Radius.circular(10)), Paint()..color = const Color(0xFF0E1628));
    final vals = [...a, ...g].whereType<double>();
    final maxV = max(100.0, vals.isEmpty ? 100 : vals.reduce(max)) * 1.15;
    const padL = 34.0, padB = 6.0, padT = 6.0;
    final w = s.width - padL - 6, h = s.height - padB - padT;
    final grid = Paint()..color = line;
    for (var i = 0; i <= 4; i++) {
      final y = padT + h - h * i / 4;
      c.drawLine(Offset(padL, y), Offset(s.width - 6, y), grid);
      final tp = TextPainter(
          text: TextSpan(text: '${(maxV * i / 4).round()}', style: const TextStyle(color: muted, fontSize: 10)),
          textDirection: TextDirection.ltr)
        ..layout();
      tp.paint(c, Offset(2, y - 6));
    }
    final step = w / (maxPts - 1), off = maxPts - a.length;
    for (var i = 0; i < a.length; i++) {
      if (a[i] == null && g[i] == null) {
        c.drawRect(Rect.fromLTWH(padL + (off + i) * step - step / 2, padT, step, h), Paint()..color = red.withOpacity(.35));
      }
    }
    void draw(List<double?> d, Color col) {
      final p = Paint()..color = col..strokeWidth = 2..style = PaintingStyle.stroke;
      final path = Path();
      bool pen = false;
      for (var i = 0; i < d.length; i++) {
        final v = d[i];
        if (v == null) {
          pen = false;
          continue;
        }
        final x = padL + (off + i) * step, y = padT + h - h * min(v, maxV) / maxV;
        pen ? path.lineTo(x, y) : path.moveTo(x, y);
        pen = true;
      }
      c.drawPath(path, p);
    }

    draw(g, green);
    draw(a, blue);
  }

  @override
  bool shouldRepaint(covariant ChartPainter o) => true;
}


/* ---------------- العدّاد (مؤشر) ---------------- */
double speedFrac(double v) => (log(1 + max(0.0, v)) / log(1001)).clamp(0.0, 1.0).toDouble();
double pingFrac(double v) => (max(0.0, v) / 300).clamp(0.0, 1.0).toDouble();
const speedTicks = <double>[0, 1, 5, 10, 50, 100, 250, 500, 1000];
const pingTicks = <double>[0, 50, 100, 150, 200, 300];
Color pingColor(double? a) =>
    a == null ? red : (a < 80 ? green : (a < 200 ? const Color(0xFFFBBF24) : red));

class Gauge extends StatelessWidget {
  final double frac;
  final String text, unit;
  final Color color;
  final List<double> ticks;
  final double Function(double) fracOf;
  const Gauge(
      {super.key,
      required this.frac,
      required this.text,
      required this.unit,
      required this.color,
      required this.ticks,
      required this.fracOf});

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: frac),
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
        builder: (_, f, __) => SizedBox(
            height: 252,
            width: double.infinity,
            child: CustomPaint(painter: GaugePainter(f, text, unit, color, ticks, fracOf))),
      );
}

class GaugePainter extends CustomPainter {
  final double frac;
  final String text, unit;
  final Color color;
  final List<double> ticks;
  final double Function(double) fracOf;
  GaugePainter(this.frac, this.text, this.unit, this.color, this.ticks, this.fracOf);

  void label(Canvas c, String s, Offset center, TextStyle st) {
    final tp = TextPainter(text: TextSpan(text: s, style: st), textDirection: TextDirection.ltr)..layout();
    tp.paint(c, center - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  void paint(Canvas c, Size s) {
    final k = min(1.0, (s.width / 2 - 6) / 122);
    c.save();
    c.translate(s.width / 2, 128);
    c.scale(k);
    const o = Offset.zero;
    const start = 150 * pi / 180, sweep = 240 * pi / 180;
    const ink = Color(0xFFE8EEFC);
    c.drawCircle(o, 122, Paint()..color = const Color(0xFF070D1A));
    c.drawCircle(o, 119, Paint()..style = PaintingStyle.stroke..strokeWidth = 2.5..color = const Color(0x8C38BDF8));
    c.drawCircle(
        o,
        116,
        Paint()
          ..shader = const RadialGradient(
                  center: Alignment(0, -0.1), radius: 0.6, colors: [Color(0xFF1C2F55), Color(0xFF0D1527)])
              .createShader(Rect.fromCircle(center: o, radius: 116)));
    c.drawArc(Rect.fromCircle(center: o, radius: 104), start + sweep * 0.86, sweep * 0.14, false,
        Paint()..style = PaintingStyle.stroke..strokeWidth = 7..color = const Color(0xFFF87171));

    Offset at(double f, double rad) {
      final a = start + sweep * f;
      return Offset(rad * cos(a), rad * sin(a));
    }

    final sorted = [...ticks]..sort();
    final thin = Paint()..color = const Color(0xFF6B7FA8)..strokeWidth = 1.2;
    for (var i = 0; i < sorted.length - 1; i++) {
      final f0 = fracOf(sorted[i]), f1 = fracOf(sorted[i + 1]);
      for (var j = 1; j < 5; j++) {
        final f = f0 + (f1 - f0) * j / 5;
        c.drawLine(at(f, 99), at(f, 92), thin);
      }
    }
    final thick = Paint()..color = ink..strokeWidth = 2.4;
    for (final t in sorted) {
      final f = fracOf(t);
      c.drawLine(at(f, 99), at(f, 86), thick);
      label(c, t.round().toString(), at(f, 72), const TextStyle(color: ink, fontSize: 11, fontWeight: FontWeight.w800));
    }
    label(c, 'SPEEDUP', const Offset(0, -38),
        const TextStyle(color: muted, fontSize: 11, fontWeight: FontWeight.w800, fontStyle: FontStyle.italic, letterSpacing: 2));

    final box = RRect.fromRectAndRadius(Rect.fromCenter(center: const Offset(0, 51), width: 92, height: 34), const Radius.circular(6));
    c.drawRRect(box, Paint()..color = const Color(0xFF070D1A));
    c.drawRRect(box, Paint()..style = PaintingStyle.stroke..strokeWidth = 1.5..color = const Color(0xFF22304F));
    label(c, text, const Offset(0, 51), TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: color, fontFamily: 'monospace'));
    label(c, unit, const Offset(0, 78), const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: muted));

    c.save();
    c.rotate(start + sweep * frac);
    final needle = Path()
      ..moveTo(88, 0)
      ..lineTo(0, -3.5)
      ..lineTo(-20, -2)
      ..lineTo(-20, 2)
      ..lineTo(0, 3.5)
      ..close();
    c.drawPath(needle, Paint()..color = color);
    c.restore();
    c.drawCircle(o, 10, Paint()..color = const Color(0xFF0B1220));
    c.drawCircle(o, 10, Paint()..style = PaintingStyle.stroke..strokeWidth = 2..color = color);
    c.restore();
  }

  @override
  bool shouldRepaint(covariant GaugePainter o) => true;
}


/* ---------------- خلفية: الأرض وأبراج الشبكة ---------------- */
class EarthPainter extends CustomPainter {
  const EarthPainter();

  void dashed(Canvas c, Path p, Paint paint, {double on = 2, double off = 6}) {
    for (final m in p.computeMetrics()) {
      double d = 0;
      while (d < m.length) {
        c.drawPath(m.extractPath(d, min(d + on, m.length)), paint);
        d += on + off;
      }
    }
  }

  void tower(Canvas c, Offset base, double angle, double sc, Paint line, Paint arcP) {
    c.save();
    c.translate(base.dx, base.dy);
    c.rotate(angle);
    c.scale(sc);
    final p = Path()
      ..moveTo(-10, 0)
      ..lineTo(0, -46)
      ..lineTo(10, 0)
      ..close()
      ..moveTo(-7, -16)
      ..lineTo(7, -16)
      ..moveTo(-4.5, -30)
      ..lineTo(4.5, -30)
      ..moveTo(-7, -16)
      ..lineTo(4.5, -30)
      ..moveTo(7, -16)
      ..lineTo(-4.5, -30);
    c.drawPath(p, line);
    c.drawCircle(const Offset(0, -48), 2.6, Paint()..color = const Color(0xFFE0F2FE));
    for (final rr in const [8.0, 14.0, 20.0]) {
      c.drawArc(Rect.fromCircle(center: const Offset(0, -48), radius: rr), -135 * pi / 180, 90 * pi / 180, false, arcP);
    }
    c.restore();
  }

  @override
  void paint(Canvas c, Size s) {
    final r = s.width * 0.9;
    final ctr = Offset(s.width / 2, s.height * 0.98);
    final k = r / 340;
    double X(double v) => ctr.dx + (v - 200) * k;
    double Y(double v) => ctr.dy + (v - 760) * k;
    final globe = Rect.fromCircle(center: ctr, radius: r);

    c.drawCircle(
        ctr,
        r,
        Paint()
          ..shader = const RadialGradient(
                  center: Alignment(0, -0.4), radius: 0.8, colors: [Color(0x8C2563EB), Color(0x000B1220)])
              .createShader(globe));
    c.drawCircle(ctr, r, Paint()..style = PaintingStyle.stroke..strokeWidth = 1.5..color = const Color(0x8C38BDF8));
    c.drawCircle(ctr, r + 8, Paint()..style = PaintingStyle.stroke..strokeWidth = 1..color = const Color(0x2E38BDF8));

    c.save();
    c.clipPath(Path()..addOval(globe));
    final grid = Paint()..style = PaintingStyle.stroke..strokeWidth = 1..color = const Color(0x4738BDF8);
    for (final f in const [0.2, 0.45, 0.75]) {
      c.drawOval(Rect.fromCenter(center: ctr, width: 2 * r * f, height: 2 * r), grid);
    }
    c.drawLine(Offset(ctr.dx, ctr.dy - r), Offset(ctr.dx, ctr.dy + r), grid);
    for (final lat in const [15.0, 30.0, 45.0, 60.0]) {
      final a = lat * pi / 180, y = ctr.dy - r * sin(a), rx = r * cos(a);
      c.drawArc(Rect.fromCenter(center: Offset(ctr.dx, y), width: 2 * rx, height: rx * 0.35), 0, pi, false, grid);
    }
    final land = Paint()..color = const Color(0x2938BDF8);
    const blobs = <List<double>>[
      [110, 500, 130, 470, 190, 470, 205, 500, 215, 530, 180, 560, 150, 555, 120, 550, 95, 530, 110, 500],
      [250, 520, 290, 495, 340, 520, 335, 560, 330, 600, 285, 610, 260, 585, 240, 565, 238, 535, 250, 520],
      [140, 640, 170, 620, 220, 640, 215, 690, 210, 730, 160, 745, 135, 715, 115, 690, 120, 655, 140, 640],
      [280, 650, 310, 640, 345, 660, 335, 700, 325, 735, 290, 730, 275, 705, 265, 685, 265, 660, 280, 650],
    ];
    for (final v in blobs) {
      final p = Path()..moveTo(X(v[0]), Y(v[1]));
      for (var i = 2; i < v.length; i += 6) {
        p.cubicTo(X(v[i]), Y(v[i + 1]), X(v[i + 2]), Y(v[i + 3]), X(v[i + 4]), Y(v[i + 5]));
      }
      c.drawPath(p..close(), land);
    }
    c.restore();

    // أبراج: ثلاثة على حافة الكرة واثنان داخلها
    final line = Paint()..style = PaintingStyle.stroke..strokeWidth = 1.6..strokeJoin = StrokeJoin.round..color = const Color(0x997DD3FC);
    final arcP = Paint()..style = PaintingStyle.stroke..strokeWidth = 1.2..strokeCap = StrokeCap.round..color = const Color(0x807DD3FC);
    final bases = <Offset>[], angles = <double>[], scales = <double>[];
    for (final th in const [-118.0, -90.0, -62.0]) {
      final a = th * pi / 180;
      bases.add(Offset(ctr.dx + r * cos(a), ctr.dy + r * sin(a)));
      angles.add((th + 90) * pi / 180);
      scales.add(k);
    }
    bases.add(Offset(X(150), Y(590)));
    angles.add(-8 * pi / 180);
    scales.add(k * .8);
    bases.add(Offset(X(265), Y(640)));
    angles.add(6 * pi / 180);
    scales.add(k * .75);

    final tops = [
      for (var i = 0; i < bases.length; i++)
        bases[i] + Offset(sin(angles[i]), -cos(angles[i])) * (48 * scales[i])
    ];
    final linkPaint = Paint()..style = PaintingStyle.stroke..strokeWidth = 1.2..strokeCap = StrokeCap.round..color = const Color(0x6638BDF8);
    for (final pr in const [[0, 1], [1, 2], [3, 0], [4, 2], [3, 4]]) {
      final a = tops[pr[0]], b = tops[pr[1]];
      final path = Path()
        ..moveTo(a.dx, a.dy)
        ..quadraticBezierTo((a.dx + b.dx) / 2, (a.dy + b.dy) / 2 - 55 * k, b.dx, b.dy);
      dashed(c, path, linkPaint);
    }
    for (var i = 0; i < bases.length; i++) {
      tower(c, bases[i], angles[i], scales[i], line, arcP);
    }
  }

  @override
  bool shouldRepaint(covariant EarthPainter o) => false;
}
