import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/player.dart';
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

  final _nameController = TextEditingController();
  final _nicknameController = TextEditingController();
  final _jerseyController = TextEditingController();
  
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    // Pre-fill the controllers if we are in "Edit Mode"
    if (widget.playerToEdit != null) {
      _nameController.text = widget.playerToEdit!.displayName;
      _nicknameController.text = widget.playerToEdit!.nickname ?? '';
      _jerseyController.text = widget.playerToEdit!.jerseyNumber?.toString() ?? '';
    }
  }

  Future<void> _submitData() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      // Create the player object
      // If editing, we MUST keep the original player's ID
      final player = Player(
        id: widget.playerToEdit?.id ?? '', 
        teamId: widget.teamId,
        displayName: _nameController.text.trim(),
        nickname: _nicknameController.text.trim(),
        jerseyNumber: int.tryParse(_jerseyController.text),
        position: 'General', 
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
          SnackBar(content: Text(widget.playerToEdit == null ? 'Player added!' : 'Player updated!')),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Dynamic title based on whether we are adding or editing
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
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Player Full Name',
                  prefixIcon: Icon(Icons.person),
                  border: OutlineInputBorder(),
                ),
                validator: (value) => 
                    (value == null || value.isEmpty) ? 'Please enter a name' : null,
              ),
              const SizedBox(height: 20),
              TextFormField(
                controller: _nicknameController,
                decoration: const InputDecoration(
                  labelText: 'Nickname (Optional)',
                  prefixIcon: Icon(Icons.badge),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 20),
              TextFormField(
                controller: _jerseyController,
                decoration: const InputDecoration(
                  labelText: 'Jersey Number (Optional)',
                  prefixIcon: Icon(Icons.numbers),
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              ),
              const SizedBox(height: 40),
              SizedBox(
                height: 50,
                child: FilledButton(
                  onPressed: _isLoading ? null : _submitData,
                  child: _isLoading 
                    ? const CircularProgressIndicator(color: Colors.white)
                    : Text(isEditing ? 'Update Player' : 'Save to Roster', 
                        style: const TextStyle(fontSize: 16)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}