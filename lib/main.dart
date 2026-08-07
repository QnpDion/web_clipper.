import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';

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
/// Використовує elementsFromPoint, щоб пропускати невидимі
/// "накладки-пастки для кліків" та службові підказки типу
/// "Click for match detail!" і знаходити реальний видимий текст.
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

  function isHiddenish(el) {
    try {
      var style = window.getComputedStyle(el);
      if (style.display === 'none' || style.visibility === 'hidden') return true;
      var rect = el.getBoundingClientRect();
      if (rect.width <= 1 || rect.height <= 1) return true;
    } catch (err) {}
    return false;
  }

  function isNoiseText(text) {
    var t = text.toLowerCase();
    return text.length < 40 && /click|detail|more info|tap here|read more|подробн|детал/.test(t);
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

    var stack = document.elementsFromPoint
      ? document.elementsFromPoint(e.clientX, e.clientY)
      : [e.target];

    var payload = null;

    for (var i = 0; i < stack.length; i++) {
      var el = stack[i];
      if (el.tagName === 'IMG' && el.src) {
        payload = { type: 'image', value: el.src };
        break;
      }
      if (isHiddenish(el)) continue;
      var text = (el.innerText || el.textContent || '').trim();
      if (text && !isNoiseText(text)) {
        payload = { type: 'text', value: text };
        break;
      }
    }

    if (!payload) {
      var el = e.target;
      var text = (el.innerText || el.textContent || '').trim();
      if (!text) {
        text = el.getAttribute('title') || el.getAttribute('alt') || '';
      }
      if (text) payload = { type: 'text', value: text };
    }

    if (payload && payload.value) {
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
  bool _hasRetried = false;
  String _currentUrl = '';
  final List<ClippedItem> _items = [];
  List<String> _bookmarks = [];
  final TextEditingController _urlController =
      TextEditingController(text: 'https://www.google.com');

  @override
  void initState() {
    super.initState();
    _loadBookmarks();
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
            final url = await _webController.currentUrl();
            if (mounted && url != null) {
              setState(() {
                _currentUrl = url;
                _urlController.text = url;
              });
            }
          },
          onWebResourceError: (error) {
            if (error.description.contains('ERR_CACHE_MISS') && !_hasRetried) {
              _hasRetried = true;
              Future.delayed(const Duration(milliseconds: 400), () {
                _webController.reload();
              });
            }
          },
        ),
      )
      ..loadRequest(Uri.parse(_urlController.text));
  }

  // ---------- Навігація / пошук ----------

  void _navigateFromInput(String value) {
    final input = value.trim();
    if (input.isEmpty) return;

    final looksLikeUrl = input.contains('.') && !input.contains(' ');
    Uri target;
    if (looksLikeUrl) {
      final withScheme = input.startsWith('http') ? input : 'https://$input';
      target = Uri.parse(withScheme);
    } else {
      target = Uri.https('www.google.com', '/search', {'q': input});
    }

    _hasRetried = false;
    _webController.loadRequest(target);
  }

  // ---------- Закладки ----------

  Future<File> _bookmarksFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/bookmarks.json');
  }

  Future<void> _loadBookmarks() async {
    try {
      final file = await _bookmarksFile();
      if (await file.exists()) {
        final content = await file.readAsString();
        final list = (jsonDecode(content) as List).cast<String>();
        if (mounted) setState(() => _bookmarks = list);
      }
    } catch (_) {
      // немає збережених закладок або файл пошкоджено — просто починаємо з порожнього списку
    }
  }

  Future<void> _saveBookmarks() async {
    try {
      final file = await _bookmarksFile();
      await file.writeAsString(jsonEncode(_bookmarks));
    } catch (_) {}
  }

  bool get _isBookmarked => _bookmarks.contains(_currentUrl);

  void _toggleBookmark() {
    if (_currentUrl.isEmpty) return;
    setState(() {
      if (_isBookmarked) {
        _bookmarks.remove(_currentUrl);
      } else {
        _bookmarks.add(_currentUrl);
      }
    });
    _saveBookmarks();
  }

  // ---------- Збір елементів ----------

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

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _tabIndex,
        children: [
          _buildBrowserTab(),
          _buildBookmarksTab(),
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
              label: Text('${_bookmarks.length}'),
              isLabelVisible: _bookmarks.isNotEmpty,
              child: const Icon(Icons.bookmark),
            ),
            label: 'Закладки',
          ),
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
                          hintText: 'Адреса сайту або пошук у Google',
                        ),
                        onSubmitted: _navigateFromInput,
                      ),
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      icon: Icon(
                        _isBookmarked ? Icons.star : Icons.star_border,
                        color: _isBookmarked ? Colors.amber : null,
                      ),
                      onPressed: _currentUrl.isEmpty ? null : _toggleBookmark,
                    ),
                    IconButton(
                      icon: const Icon(Icons.refresh),
                      onPressed: () {
                        _hasRetried = false;
                        _webController.reload();
                      },
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

  Widget _buildBookmarksTab() {
    return SafeArea(
      child: _bookmarks.isEmpty
          ? const Center(
              child: Text(
                'Закладок ще немає.\nВідкрий сайт і натисни зірочку в браузері, щоб додати.',
                textAlign: TextAlign.center,
              ),
            )
          : ListView.separated(
              itemCount: _bookmarks.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final url = _bookmarks[index];
                return ListTile(
                  leading: const Icon(Icons.public),
                  title: Text(url, maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () {
                    _hasRetried = false;
                    _webController.loadRequest(Uri.parse(url));
                    setState(() => _tabIndex = 0);
                  },
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () {
                      setState(() => _bookmarks.removeAt(index));
                      _saveBookmarks();
                    },
                  ),
                );
              },
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