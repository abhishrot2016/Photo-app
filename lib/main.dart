// Who's Who: offline app with Folders, Dark Mode, and Backup/Restore.
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sqflite/sqflite.dart';

late Database db;
late String photosDir;
late String dbPath;

final List<String> kCategories = ['Family', 'Friends', 'Classmates', 'Colleagues', 'Others'];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final docs = await getApplicationDocumentsDirectory();
  photosDir = p.join(docs.path, 'photos');
  await Directory(photosDir).create(recursive: true);
  
  dbPath = p.join(await getDatabasesPath(), 'whos_who.db');
  await _initDatabase();

  runApp(const WhosWhoApp());
}

Future<void> _initDatabase() async {
  db = await openDatabase(
    dbPath,
    version: 2,
    onCreate: (d, v) async {
      await d.execute(
        'CREATE TABLE people('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, '
        'name TEXT NOT NULL, '
        'category TEXT NOT NULL, '
        'description TEXT NOT NULL, '
        'photo TEXT NOT NULL)',
      );
    },
    onUpgrade: (d, oldVersion, newVersion) async {
      if (oldVersion < 2) {
        await d.execute('ALTER TABLE people ADD COLUMN category TEXT NOT NULL DEFAULT "Friends"');
      }
    },
  );
}

class Person {
  Person({
    this.id,
    required this.name,
    required this.category,
    required this.description,
    required this.photo,
  });

  final int? id;
  final String name, category, description, photo;

  factory Person.fromMap(Map<String, Object?> m) => Person(
        id: m['id'] as int?,
        name: m['name'] as String? ?? '',
        category: m['category'] as String? ?? 'Friends',
        description: m['description'] as String? ?? '',
        photo: m['photo'] as String? ?? '',
      );

  File get file => File(p.join(photosDir, photo));

  Future<void> deletePhoto() async {
    if (await file.exists()) await file.delete();
  }
}

class WhosWhoApp extends StatefulWidget {
  const WhosWhoApp({super.key});

  @override
  State<WhosWhoApp> createState() => _WhosWhoAppState();
}

class _WhosWhoAppState extends State<WhosWhoApp> {
  ThemeMode _themeMode = ThemeMode.light;

  void _toggleTheme() {
    setState(() {
      _themeMode = _themeMode == ThemeMode.light ? ThemeMode.dark : ThemeMode.light;
    });
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: "Who's Who",
        debugShowCheckedModeBanner: false,
        themeMode: _themeMode,
        theme: ThemeData(
          colorSchemeSeed: const Color(0xFF2A6F77),
          useMaterial3: true,
          brightness: Brightness.light,
        ),
        darkTheme: ThemeData(
          colorSchemeSeed: const Color(0xFF2A6F77),
          useMaterial3: true,
          brightness: Brightness.dark,
        ),
        home: HomePage(
          onToggleTheme: _toggleTheme,
          currentThemeMode: _themeMode,
        ),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.onToggleTheme, required this.currentThemeMode});

  final VoidCallback onToggleTheme;
  final ThemeMode currentThemeMode;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<Person> _people = [];
  String _query = '';
  String _selectedFilter = 'All';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final q = '%$_query%';
    List<Map<String, Object?>> rows;

    if (_selectedFilter == 'All') {
      rows = await db.query(
        'people',
        where: 'name LIKE ? OR description LIKE ?',
        whereArgs: [q, q],
        orderBy: 'name COLLATE NOCASE',
      );
    } else {
      rows = await db.query(
        'people',
        where: 'category = ? AND (name LIKE ? OR description LIKE ?)',
        whereArgs: [_selectedFilter, q, q],
        orderBy: 'name COLLATE NOCASE',
      );
    }

    if (mounted) setState(() => _people = rows.map(Person.fromMap).toList());
  }

  Future<void> _open(Widget page) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => page));
    _load();
  }

  void _toast(String message) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  // --- EXPORT BACKUP TO NEW PHONE ---
  Future<void> _exportBackup() async {
    try {
      final encoder = ZipFileEncoder();
      final tempDir = await getTemporaryDirectory();
      final backupFile = File(p.join(tempDir.path, 'whos_who_backup.zip'));
      if (await backupFile.exists()) await backupFile.delete();

      encoder.create(backupFile.path);
      // Add database file
      encoder.addFile(File(dbPath));
      // Add all photos directory
      encoder.addDirectory(Directory(photosDir));
      encoder.close();

      // Share the file via Bluetooth, Nearby Share, WhatsApp, etc.
      await Share.shareXFiles([XFile(backupFile.path)], text: 'Who\'s Who Offline Backup');
    } catch (e) {
      _toast('Failed to create backup: $e');
    }
  }

  // --- IMPORT BACKUP FROM OLD PHONE ---
  Future<void> _importBackup() async {
    try {
      final result = await FilePicker.platform.pickFiles(type: FileType.any);
      if (result == null || result.files.single.path == null) return;

      final zipFile = File(result.files.single.path!);
      
      // Confirm import
      final confirm = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Restore Backup?'),
          content: const Text('This will merge or overwrite current data with the backup file.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Restore')),
          ],
        ),
      );

      if (confirm != true) return;

      // Extract zip bytes
      final bytes = await zipFile.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      final docs = await getApplicationDocumentsDirectory();

      for (final file in archive) {
        final filename = file.name;
        if (file.isFile) {
          final data = file.content as List<int>;
          // Check if it's database or photo
          if (filename.endsWith('.db')) {
            File(dbPath)
              ..createSync(recursive: true)
              ..writeAsBytesSync(data);
          } else {
            File(p.join(docs.path, filename))
              ..createSync(recursive: true)
              ..writeAsBytesSync(data);
          }
        }
      }

      // Re-initialize database connection
      await db.close();
      await _initDatabase();
      await _load();

      _toast('Backup restored successfully!');
    } catch (e) {
      _toast('Failed to restore backup: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final filterOptions = ['All', ...kCategories];

    return Scaffold(
      appBar: AppBar(
        title: const Text("Who's Who"),
        actions: [
          IconButton(
            icon: Icon(widget.currentThemeMode == ThemeMode.dark ? Icons.light_mode : Icons.dark_mode),
            tooltip: 'Toggle Dark Mode',
            onPressed: widget.onToggleTheme,
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'export') _exportBackup();
              if (value == 'import') _importBackup();
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'export', child: Text('📤 Export Backup (.zip)')),
              const PopupMenuItem(value: 'import', child: Text('📥 Restore Backup (.zip)')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              decoration: const InputDecoration(
                hintText: 'Search names and notes',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
              onChanged: (v) {
                _query = v.trim();
                _load();
              },
            ),
          ),
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: filterOptions.map((cat) {
                final isSelected = _selectedFilter == cat;
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: ChoiceChip(
                    label: Text(cat),
                    selected: isSelected,
                    onSelected: (selected) {
                      setState(() {
                        _selectedFilter = cat;
                      });
                      _load();
                    },
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: _people.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        _query.isEmpty && _selectedFilter == 'All'
                            ? 'Nobody saved yet.\nTap "Add person" to save a photo and notes.'
                            : 'No one found in "$_selectedFilter".',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 88),
                    itemCount: _people.length,
                    itemBuilder: (_, i) {
                      final person = _people[i];
                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                        leading: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.file(
                            person.file,
                            width: 64,
                            height: 64,
                            cacheWidth: 160,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => const Icon(Icons.person, size: 48),
                          ),
                        ),
                        title: Text(
                          person.name,
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 2),
                            Text(
                              '📁 ${person.category}',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(person.description, maxLines: 2, overflow: TextOverflow.ellipsis),
                          ],
                        ),
                        onTap: () => _open(DetailPage(person: person)),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _open(const EditPage()),
        icon: const Icon(Icons.add_a_photo),
        label: const Text('Add person'),
      ),
    );
  }
}

// -------------------------------------------------------------- detail screen

class DetailPage extends StatelessWidget {
  const DetailPage({super.key, required this.person});

  final Person person;

  Future<void> _edit(BuildContext context) async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => EditPage(person: person)),
    );
    if (saved == true && context.mounted) Navigator.pop(context);
  }

  Future<void> _delete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Delete ${person.name}?'),
        content: const Text('The photo and notes will be removed from this phone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    await db.delete('people', where: 'id = ?', whereArgs: [person.id]);
    await person.deletePhoto();
    if (context.mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(person.name),
        actions: [
          IconButton(icon: const Icon(Icons.edit), tooltip: 'Edit', onPressed: () => _edit(context)),
          IconButton(icon: const Icon(Icons.delete), tooltip: 'Delete', onPressed: () => _delete(context)),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Image.file(person.file, width: double.infinity, fit: BoxFit.fitWidth),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Chip(
                label: Text(person.category),
                avatar: const Icon(Icons.folder, size: 16),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(person.name, style: text.headlineMedium),
          const SizedBox(height: 8),
          Text(person.description.isEmpty ? 'No notes.' : person.description, style: text.bodyLarge),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------ add/edit screen

class EditPage extends StatefulWidget {
  const EditPage({super.key, this.person});

  final Person? person;

  @override
  State<EditPage> createState() => _EditPageState();
}

class _EditPageState extends State<EditPage> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.person?.name);
  late final _desc = TextEditingController(text: widget.person?.description);
  late String _category = widget.person?.category ?? 'Friends';
  File? _picked;

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    super.dispose();
  }

  void _toast(String message) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _pick(ImageSource source) async {
    try {
      final x = await ImagePicker().pickImage(
        source: source,
        maxWidth: 800,
        maxHeight: 800,
        imageQuality: 75,
      );
      if (x != null && mounted) setState(() => _picked = File(x.path));
    } catch (_) {
      _toast('Could not open the camera or your files. Check permissions in Settings.');
    }
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final old = widget.person;
    if (old == null && _picked == null) {
      _toast('Add a photo first.');
      return;
    }
    var photo = old?.photo ?? '';
    if (_picked != null) {
      photo = '${DateTime.now().millisecondsSinceEpoch}.jpg';
      await _picked!.copy(p.join(photosDir, photo));
      await old?.deletePhoto();
    }
    final values = <String, Object?>{
      'name': _name.text.trim(),
      'category': _category,
      'description': _desc.text.trim(),
      'photo': photo,
    };
    if (old == null) {
      await db.insert('people', values);
    } else {
      await db.update('people', values, where: 'id = ?', whereArgs: [old.id]);
    }
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final shown = _picked ?? widget.person?.file;
    return Scaffold(
      appBar: AppBar(title: Text(widget.person == null ? 'Add person' : 'Edit person')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Container(
              height: 260,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceVariant,
                borderRadius: BorderRadius.circular(16),
              ),
              child: shown == null
                  ? const Center(child: Icon(Icons.person_outline, size: 96))
                  : Image.file(shown, fit: BoxFit.contain),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _pick(ImageSource.camera),
                    icon: const Icon(Icons.photo_camera),
                    label: const Text('Take photo'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _pick(ImageSource.gallery),
                    icon: const Icon(Icons.folder_open),
                    label: const Text('Choose photo'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Name', border: OutlineInputBorder()),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter a name.' : null,
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              value: _category,
              decoration: const InputDecoration(
                labelText: 'Category / Folder',
                border: OutlineInputBorder(),
              ),
              items: kCategories.map((cat) {
                return DropdownMenuItem(
                  value: cat,
                  child: Text(cat),
                );
              }).toList(),
              onChanged: (val) {
                if (val != null) setState(() => _category = val);
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _desc,
              minLines: 3,
              maxLines: 6,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Notes',
                hintText: 'Who are they? Where did you meet?',
                alignLabelWithHint: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.check),
              label: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }
}
