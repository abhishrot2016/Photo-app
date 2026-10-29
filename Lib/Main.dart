// Who's Who: a small offline app for remembering faces and names.
// Photos are shrunk and kept in the app's private storage on the phone;
// names and notes live in a local SQLite database. No internet is used.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

late final Database db;
late final String photosDir;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final docs = await getApplicationDocumentsDirectory();
  photosDir = p.join(docs.path, 'photos');
  await Directory(photosDir).create(recursive: true);
  db = await openDatabase(
    p.join(await getDatabasesPath(), 'whos_who.db'),
    version: 1,
    onCreate: (d, _) => d.execute(
      'CREATE TABLE people('
      'id INTEGER PRIMARY KEY AUTOINCREMENT, '
      'name TEXT NOT NULL, description TEXT NOT NULL, photo TEXT NOT NULL)',
    ),
  );
  runApp(const WhosWhoApp());
}

class Person {
  Person({this.id, required this.name, required this.description, required this.photo});

  final int? id;
  final String name, description, photo; // photo = file name inside photosDir

  factory Person.fromMap(Map<String, Object?> m) => Person(
        id: m['id'] as int,
        name: m['name'] as String,
        description: m['description'] as String,
        photo: m['photo'] as String,
      );

  File get file => File(p.join(photosDir, photo));

  Future<void> deletePhoto() async {
    if (await file.exists()) await file.delete();
  }
}

class WhosWhoApp extends StatelessWidget {
  const WhosWhoApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: "Who's Who",
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: const Color(0xFF2A6F77), useMaterial3: true),
        home: const HomePage(),
      );
}

// ---------------------------------------------------------------- list screen

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<Person> _people = [];
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final q = '%$_query%';
    final rows = await db.query(
      'people',
      where: 'name LIKE ? OR description LIKE ?',
      whereArgs: [q, q],
      orderBy: 'name COLLATE NOCASE',
    );
    if (mounted) setState(() => _people = rows.map(Person.fromMap).toList());
  }

  Future<void> _open(Widget page) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => page));
    _load(); // refresh after adding, editing or deleting
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Who's Who")),
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
          Expanded(
            child: _people.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        _query.isEmpty
                            ? 'Nobody saved yet.\nTap "Add person" to save a photo and a few notes.'
                            : 'No one matches "$_query".',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 88), // room for the button
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
                        subtitle: Text(person.description, maxLines: 2, overflow: TextOverflow.ellipsis),
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

  final Person? person; // null = adding someone new

  @override
  State<EditPage> createState() => _EditPageState();
}

class _EditPageState extends State<EditPage> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.person?.name);
  late final _desc = TextEditingController(text: widget.person?.description);
  File? _picked; // new photo chosen but not saved yet

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
      // Shrunk to at most 800 px and re-compressed: small file, still easy to recognise.
      final x = await ImagePicker().pickImage(
        source: source,
        maxWidth: 800,
        maxHeight: 800,
        imageQuality: 75,
      );
      if (x != null && mounted) setState(() => _picked = File(x.path));
    } catch (_) {
      _toast('Could not open the camera or your files. Check the app\'s permissions in Settings.');
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
      await old?.deletePhoto(); // replace the old photo
    }
    final values = <String, Object?>{
      'name': _name.text.trim(),
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
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
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
