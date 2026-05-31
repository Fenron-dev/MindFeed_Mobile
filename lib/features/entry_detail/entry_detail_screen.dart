import 'package:flutter/material.dart';

class EntryDetailScreen extends StatelessWidget {
  final String entryId;
  const EntryDetailScreen({super.key, required this.entryId});
  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: Text('Eintrag $entryId')),
      body: const Center(child: Text('Detail — kommt bald')));
}
