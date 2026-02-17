import 'package:flutter/material.dart';
import 'package:sweatdex/models/player.dart';
import '../services/player_service.dart';

class AddPlayerScreen extends StatefulWidget {
  final String teamId;
  final Player? playerToEdit;

  const AddPlayerScreen({super.key, required this.teamId, this.playerToEdit});

  @override
  State<AddPlayerScreen> createState() => _AddPlayerScreenState();
}

class _AddPlayerScreenState extends State<AddPlayerScreen> {
  final _formKey = GlobalKey<FormState>();
  final _playerService = PlayerService();
  
  // Controllers for all player fields
  final _nameController = TextEditingController();
  final _nicknameController = TextEditingController();
  final _jerseyController = TextEditingController();
  final _studentIdController = TextEditingController();
  final _studentEmailController = TextEditingController();

  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    // Pre-fill the controllers if we are in "Edit Mode"
    if (widget.playerToEdit != null) {
      final player = widget.playerToEdit!;
      _nameController.text = player.name;
      _nicknameController.text = player.nickname ?? '';
      _jerseyController.text = player.jerseyNumber ?? '';
      _studentIdController.text = player.studentId ?? '';
      _studentEmailController.text = player.studentEmail ?? '';
    }
  }

  Future<void> _submitData() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      // Create the player object
      final player = Player(
        id: widget.playerToEdit?.id ?? '', // Keep existing ID if editing
        teamId: widget.teamId,
        name: _nameController.text.trim(),
        nickname: _nicknameController.text.trim().isEmpty 
            ? null 
            : _nicknameController.text.trim(),
        jerseyNumber: _jerseyController.text.trim().isEmpty 
            ? null 
            : _jerseyController.text.trim(),
        studentId: _studentIdController.text.trim().isEmpty 
            ? null 
            : _studentIdController.text.trim(),
        studentEmail: _studentEmailController.text.trim().isEmpty 
            ? null 
            : _studentEmailController.text.trim(),
      );

      if (widget.playerToEdit == null) {
        // Mode: Add
        await _playerService.addPlayer(player);
      } else {
        // Mode: Edit
        await _playerService.updatePlayer(player);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.playerToEdit == null 
                  ? '${player.name} added to roster!' 
                  : '${player.name} updated!',
            ),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _nicknameController.dispose();
    _jerseyController.dispose();
    _studentIdController.dispose();
    _studentEmailController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool isEditing = widget.playerToEdit != null;

    return Scaffold(
      appBar: AppBar(
        title: Text(isEditing ? 'Edit Player' : 'Add New Player'),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Form(
          key: _formKey,
          child: ListView(
            children: [
              // Name (Required)
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Player Full Name *',
                  hintText: 'e.g., John Smith',
                  prefixIcon: Icon(Icons.person),
                  border: OutlineInputBorder(),
                ),
                textCapitalization: TextCapitalization.words,
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Please enter a name';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),

              // Jersey Number (Optional)
              TextFormField(
                controller: _jerseyController,
                decoration: const InputDecoration(
                  labelText: 'Jersey Number',
                  hintText: 'e.g., 23, 00, 12A',
                  prefixIcon: Icon(Icons.numbers),
                  border: OutlineInputBorder(),
                  helperText: 'Can include letters (e.g., 12A)',
                ),
                textCapitalization: TextCapitalization.characters,
              ),
              const SizedBox(height: 16),

              // Nickname (Optional)
              TextFormField(
                controller: _nicknameController,
                decoration: const InputDecoration(
                  labelText: 'Nickname',
                  hintText: 'e.g., Big Mike',
                  prefixIcon: Icon(Icons.badge),
                  border: OutlineInputBorder(),
                ),
                textCapitalization: TextCapitalization.words,
              ),
              const SizedBox(height: 16),

              // Divider
              const Divider(height: 32),
              Text(
                'Student Information (Optional)',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(height: 16),

              // Student ID (Optional)
              TextFormField(
                controller: _studentIdController,
                decoration: const InputDecoration(
                  labelText: 'Student ID',
                  hintText: 'e.g., S12345',
                  prefixIcon: Icon(Icons.badge_outlined),
                  border: OutlineInputBorder(),
                ),
                textCapitalization: TextCapitalization.characters,
              ),
              const SizedBox(height: 16),

              // Student Email (Optional)
              TextFormField(
                controller: _studentEmailController,
                decoration: const InputDecoration(
                  labelText: 'Student Email',
                  hintText: 'e.g., student@school.edu',
                  prefixIcon: Icon(Icons.email_outlined),
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.emailAddress,
                validator: (value) {
                  if (value != null && value.isNotEmpty && !value.contains('@')) {
                    return 'Please enter a valid email';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 32),

              // Submit Button
              SizedBox(
                height: 50,
                child: FilledButton(
                  onPressed: _isLoading ? null : _submitData,
                  child: _isLoading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        )
                      : Text(
                          isEditing ? 'Update Player' : 'Add to Roster',
                          style: const TextStyle(fontSize: 16),
                        ),
                ),
              ),

              // Cancel button for edit mode
              if (isEditing) ...[
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}