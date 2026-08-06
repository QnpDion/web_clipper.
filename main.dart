import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:share_plus/share_plus.dart';

void main() {
  runApp(const WebClipperApp());
}

class WebClipperApp extends StatelessWidget {
  const WebClipperApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Web Clipper',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
      ),
      home: const HomeShell(),
    );
  }
}

/// JavaScript, що вбудовується на кожній сторінці.
/// Підсвічує елемент під курсором/пальцем і при кліку
/// відправляє його текст (або src, якщо це картинка) у Flutter.
const String _clipperJs = r'''
(function () {
  if (window.__clipperInstalled) return;
  window.__clipperInstalled = true;
  window.__collectModeOn = false;

  var lastHighlighted = null;

  function clearHighlight() {
    if (lastHighlighted) {
      lastHighlighted.style.outline = '';
      lastHighlighted.style.outlineOffset = '';
      lastHighlighted = null;
    }
  }

  document.addEventListener('mouseover', function (e) {
    if (!window.__collectModeOn) return;
    clearHighlight();
    e.target.style.outline = '2px solid #4F46E5';
    e.target.style.outlineOffset = '1px';
    lastHighlighted = e.target;
  }, true);

  document.addEventListener('mouseout', function (e) {
    if (!window.__collectModeOn) return;
    clearHighlight();
  }, true);

  document.addEventListener('click', function (e) {
    if (!window.__collectModeOn) return;
    e.preventDefault();
    e.stopPropagation();

    var el = e.target;
    var payload;

    if (el.tagName === 'IMG' && el.src) {
      payload = { type: 'image', value: el.src };
    } else {
      var text = (el.innerText || el.textContent || '').trim();
      if (!text) {
        // якщо елемент без прямого тексту (напр. іконка), пробуємо title/alt
        text = el.getAttribute('title') || el.getAttribute('alt') || '';
      }
      payload = { type: 'text', value: text };
    }

    if (payload.value) {
      ClipChannel.postMessage(JSON.stringify(payload));
    }
  }, true);
})();
''';

class ClippedItem {
  final String type; // 'text' | 'image'
  final String value;
  final DateTime addedAt;

  ClippedItem({required this.type, required this.value, required this.addedAt});
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tabIndex = 0;
  bool _collectMode = false;
  late final WebViewController _webController;
  final List<ClippedItem> _items = [];
  final TextEditingController _urlController =
      TextEditingController(text: 'https://uk.wikipedia.org');

  @override
  void initState() {
    super.initState();
    _webController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'ClipChannel',
        onMessageReceived: _handleClip,
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) async {
            await _webController.runJavaScript(_clipperJs);
            await _setCollectModeJs(_collectMode);
          },
        ),
      )
      ..loadRequest(Uri.parse(_urlController.text));
  }

  void _handleClip(JavaScriptMessage message) {
    try {
      final data = jsonDecode(message.message) as Map<String, dynamic>;
      final type = data['type'] as String;
      final value = (data['value'] as String).trim();
      if (value.isEmpty) return;
      setState(() {
        _items.add(ClippedItem(type: type, value: value, addedAt: DateTime.now()));
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(type == 'image' ? 'Додано картинку' : 'Додано: $value'),
          duration: const Duration(milliseconds: 900),
        ),
      );
    } catch (_) {
      // ігноруємо некоректні повідомлення
    }
  }

  Future<void> _setCollectModeJs(bool enabled) async {
    await _webController.runJavaScript('window.__collectModeOn = $enabled;');
  }

  Future<void> _toggleCollectMode() async {
    setState(() => _collectMode = !_collectMode);
    await _setCollectModeJs(_collectMode);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_collectMode
              ? 'Режим збору увімкнено — клікай на елементи сторінки'
              : 'Режим збору вимкнено — звичайний браузинг'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  void _removeItem(int index) {
    setState(() => _items.removeAt(index));
  }

  void _clearAll() {
    setState(() => _items.clear());
  }

  String _itemsAsText() {
    return _items
        .map((e) => e.type == 'image' ? '[картинка] ${e.value}' : e.value)
        .join('\n');
  }

  Future<void> _copyAll() async {
    final text = _itemsAsText();
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Список скопійовано')),
      );
    }
  }

  Future<void> _shareAll() async {
    final text = _itemsAsText();
    if (text.isEmpty) return;
    await Share.share(text);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _tabIndex,
        children: [
          _buildBrowserTab(),
          _buildListTab(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabIndex,
        onDestinationSelected: (i) => setState(() => _tabIndex = i),
        destinations: [
          const NavigationDestination(icon: Icon(Icons.public), label: 'Браузер'),
          NavigationDestination(
            icon: Badge(
              label: Text('${_items.length}'),
              isLabelVisible: _items.isNotEmpty,
              child: const Icon(Icons.list_alt),
            ),
            label: 'Список',
          ),
        ],
      ),
    );
  }

  Widget _buildBrowserTab() {
    return SafeArea(
      child: Stack(
        children: [
          Column(
            children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _urlController,
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.go,
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                      hintText: 'Введи адресу сайту',
                    ),
                    onSubmitted: (value) {
                      var url = value.trim();
                      if (!url.startsWith('http')) url = 'https://$url';
                      _webController.loadRequest(Uri.parse(url));
                    },
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: () => _webController.reload(),
                ),
              ],
            ),
          ),
              Expanded(child: WebViewWidget(controller: _webController)),
            ],
          ),
          Positioned(
            right: 16,
            bottom: 16,
            child: FloatingActionButton.extended(
              onPressed: _toggleCollectMode,
              backgroundColor: _collectMode ? Colors.green : null,
              icon: Icon(_collectMode ? Icons.touch_app : Icons.touch_app_outlined),
              label: Text(_collectMode ? 'Збір: УВІМК' : 'Режим збору'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildListTab() {
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Text('Зібрано: ${_items.length}', style: const TextStyle(fontWeight: FontWeight.bold)),
                const Spacer(),
                IconButton(
                  tooltip: 'Копіювати все',
                  icon: const Icon(Icons.copy_all),
                  onPressed: _items.isEmpty ? null : _copyAll,
                ),
                IconButton(
                  tooltip: 'Поділитися / експорт',
                  icon: const Icon(Icons.ios_share),
                  onPressed: _items.isEmpty ? null : _shareAll,
                ),
                IconButton(
                  tooltip: 'Очистити все',
                  icon: const Icon(Icons.delete_sweep),
                  onPressed: _items.isEmpty ? null : _clearAll,
                ),
              ],
            ),
          ),
          Expanded(
            child: _items.isEmpty
                ? const Center(child: Text('Список порожній.\nУвімкни режим збору у браузері й клікай на елементи.', textAlign: TextAlign.center))
                : ListView.separated(
                    itemCount: _items.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final item = _items[index];
                      return ListTile(
                        leading: Icon(item.type == 'image' ? Icons.image : Icons.short_text),
                        title: Text(
                          item.value,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => _removeItem(index),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

