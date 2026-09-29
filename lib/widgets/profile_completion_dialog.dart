import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/dpc_tokens.dart';
import '../providers/auth_providers.dart';
import '../providers/supabase_provider.dart';

/// Interactive modal dialog prompting users (especially Apple Sign In users)
/// to complete their profile with compulsory Full Name, Date of Birth, and Gender.
class ProfileCompletionDialog extends ConsumerStatefulWidget {
  final String? initialName;
  final DateTime? initialDob;
  final String? initialGender;
  final bool isMandatory;

  const ProfileCompletionDialog({
    super.key,
    this.initialName,
    this.initialDob,
    this.initialGender,
    this.isMandatory = true,
  });

  /// Static helper to display the profile completion dialog
  static Future<bool?> show(
    BuildContext context, {
    String? initialName,
    DateTime? initialDob,
    String? initialGender,
    bool isMandatory = true,
  }) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: !isMandatory,
      builder: (_) => ProfileCompletionDialog(
        initialName: initialName,
        initialDob: initialDob,
        initialGender: initialGender,
        isMandatory: isMandatory,
      ),
    );
  }

  @override
  ConsumerState<ProfileCompletionDialog> createState() =>
      _ProfileCompletionDialogState();
}

class _ProfileCompletionDialogState
    extends ConsumerState<ProfileCompletionDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  DateTime? _selectedDob;
  String? _selectedGender;
  bool _isSaving = false;
  String? _errorMessage;

  late String _originalName;
  DateTime? _originalDob;
  String? _originalGender;

  static const List<String> _genderOptions = [
    'Male',
    'Female',
    'Non-Binary',
    'Prefer not to say',
  ];

  @override
  void initState() {
    super.initState();
    final name = widget.initialName?.trim();
    _originalName = (name != null && name != 'Setthi Member') ? name : '';
    _originalDob = widget.initialDob;
    final initialG = widget.initialGender?.trim();
    _originalGender = (initialG != null && _genderOptions.contains(initialG))
        ? initialG
        : null;

    _nameController = TextEditingController(text: _originalName);
    _nameController.addListener(_onFieldChanged);
    _selectedDob = _originalDob;
    _selectedGender = _originalGender;
  }

  void _onFieldChanged() {
    setState(() {});
  }

  @override
  void didUpdateWidget(ProfileCompletionDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_isSameDay(widget.initialDob, oldWidget.initialDob)) {
      _originalDob = widget.initialDob;
      _selectedDob = widget.initialDob;
    }
    if (widget.initialGender != oldWidget.initialGender) {
      final initialG = widget.initialGender?.trim();
      _originalGender = (initialG != null && _genderOptions.contains(initialG))
          ? initialG
          : null;
      _selectedGender = _originalGender;
    }
    if (widget.initialName != oldWidget.initialName) {
      final name = widget.initialName?.trim();
      _originalName = (name != null && name != 'Setthi Member') ? name : '';
      _nameController.text = _originalName;
    }
  }

  @override
  void dispose() {
    _nameController.removeListener(_onFieldChanged);
    _nameController.dispose();
    super.dispose();
  }

  bool _isSameDay(DateTime? a, DateTime? b) {
    if (a == null && b == null) return true;
    if (a == null || b == null) return false;
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  bool get _hasChanges {
    final name = _nameController.text.trim();
    final bool nameChanged = name != _originalName;
    final bool dobChanged = !_isSameDay(_selectedDob, _originalDob);
    final bool genderChanged = _selectedGender != _originalGender;
    return nameChanged || dobChanged || genderChanged;
  }

  bool get _isFormValid {
    final name = _nameController.text.trim();
    final hasValidName = name.length >= 2;
    final hasDob = _selectedDob != null;
    final hasGender = _selectedGender != null && _selectedGender!.isNotEmpty;
    return hasValidName && hasDob && hasGender && _hasChanges;
  }

  String _formatDate(DateTime dt) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${dt.day.toString().padLeft(2, '0')} ${months[dt.month - 1]} ${dt.year}';
  }

  int _calculateAge(DateTime dob) {
    final now = DateTime.now();
    int age = now.year - dob.year;
    if (now.month < dob.month ||
        (now.month == dob.month && now.day < dob.day)) {
      age--;
    }
    return age;
  }

  Future<void> _pickDateOfBirth() async {
    final now = DateTime.now();
    final initial = _selectedDob ?? DateTime(now.year - 20, now.month, now.day);
    final firstDate = DateTime(1900, 1, 1);
    final lastDate = now;

    final picked = await showDatePicker(
      context: context,
      initialDate: initial.isBefore(firstDate)
          ? firstDate
          : (initial.isAfter(lastDate) ? lastDate : initial),
      firstDate: firstDate,
      lastDate: lastDate,
      helpText: 'SELECT DATE OF BIRTH',
      builder: (context, child) {
        return Theme(
          data: ThemeData.dark().copyWith(
            colorScheme: const ColorScheme.dark(
              primary: DpcColors.accentPositive,
              onPrimary: Colors.black,
              surface: DpcColors.surfaceDark,
              onSurface: DpcColors.textPrimary,
            ),
            dialogTheme: const DialogThemeData(
              backgroundColor: DpcColors.surfaceDark,
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked != null) {
      setState(() {
        _selectedDob = picked;
        _errorMessage = null;
      });
    }
  }

  Future<void> _handleSave() async {
    if (!_isFormValid) return;
    setState(() => _errorMessage = null);

    final user = ref.read(currentUserProvider);
    if (user == null) return;

    setState(() => _isSaving = true);

    final fullName = _nameController.text.trim();
    final calculatedAge = _calculateAge(_selectedDob!);

    try {
      final dbService = ref.read(supabaseDbServiceProvider);
      await dbService.upsertProfile(
        userId: user.id,
        email: user.email ?? '',
        fullName: fullName,
        dateOfBirth: _selectedDob,
        age: calculatedAge,
        gender: _selectedGender,
      );

      try {
        final client = ref.read(supabaseClientProvider);
        await client?.auth.updateUser(
          UserAttributes(data: {'full_name': fullName}),
        );
      } catch (_) {}

      ref.invalidate(userProfileProvider);

      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Failed to save profile: $e';
          _isSaving = false;
        });
      }
    }
  }

  InputDecoration _buildInputDecoration({
    required String hint,
    required IconData icon,
  }) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: DpcColors.textMuted, fontSize: 13),
      prefixIcon: Icon(icon, color: DpcColors.textSecondary, size: 18),
      filled: true,
      fillColor: DpcColors.bgOled,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: DpcColors.surfaceBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: DpcColors.surfaceBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: DpcColors.accentPositive),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: DpcColors.accentNegative),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: DpcColors.accentNegative),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const mintAccent = DpcColors.accentPositive;
    final isReady = _isFormValid && !_isSaving;

    return PopScope(
      canPop: !widget.isMandatory,
      child: Dialog(
        backgroundColor: DpcColors.surfaceDark,
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: const BorderSide(color: DpcColors.surfaceBorder, width: 1),
        ),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(22),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header Icon & Title
                  Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: DpcColors.surfaceTrack,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: DpcColors.surfaceBorder,
                            width: 1,
                          ),
                        ),
                        child: const Icon(
                          Icons.badge_outlined,
                          color: DpcColors.textPrimary,
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 14),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Complete Your Profile',
                              style: TextStyle(
                                color: DpcColors.textPrimary,
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.3,
                              ),
                            ),
                            SizedBox(height: 2),
                            Text(
                              'All fields are required to continue',
                              style: TextStyle(
                                color: DpcColors.textSecondary,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (!widget.isMandatory)
                        GestureDetector(
                          onTap: () => Navigator.of(context).pop(false),
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: DpcColors.surfaceTrack,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: DpcColors.surfaceBorder,
                                width: 1,
                              ),
                            ),
                            child: const Icon(
                              Icons.close,
                              color: DpcColors.textSecondary,
                              size: 16,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 20),

                  // Error message banner
                  if (_errorMessage != null) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      margin: const EdgeInsets.only(bottom: 14),
                      decoration: BoxDecoration(
                        color: DpcColors.accentNegative.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: DpcColors.accentNegative.withValues(
                            alpha: 0.3,
                          ),
                        ),
                      ),
                      child: Text(
                        _errorMessage!,
                        style: const TextStyle(
                          color: DpcColors.accentNegative,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],

                  // 1. Full Name Input
                  Row(
                    children: const [
                      Text(
                        'Full Name',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        ' *',
                        style: TextStyle(
                          color: DpcColors.accentNegative,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  TextFormField(
                    controller: _nameController,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    decoration: _buildInputDecoration(
                      hint: 'Enter your full name',
                      icon: Icons.person_outline_rounded,
                    ),
                    validator: (val) {
                      if (val == null || val.trim().isEmpty) {
                        return 'Please enter your full name';
                      }
                      if (val.trim().length < 2) {
                        return 'Name must be at least 2 characters';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),

                  // 2. Date of Birth Input
                  Row(
                    children: const [
                      Text(
                        'Date of Birth',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        ' *',
                        style: TextStyle(
                          color: DpcColors.accentNegative,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  InkWell(
                    key: const Key('profile_dob_picker_tile'),
                    onTap: _pickDateOfBirth,
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: DpcColors.bgOled,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: _selectedDob != null
                              ? mintAccent.withValues(alpha: 0.5)
                              : DpcColors.surfaceBorder,
                          width: 1,
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.calendar_month_outlined,
                            color: DpcColors.textSecondary,
                            size: 18,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _selectedDob != null
                                  ? _formatDate(_selectedDob!)
                                  : 'Select Date of Birth',
                              style: TextStyle(
                                color: _selectedDob != null
                                    ? Colors.white
                                    : DpcColors.textMuted,
                                fontSize: 14,
                                fontWeight: _selectedDob != null
                                    ? FontWeight.w600
                                    : FontWeight.normal,
                              ),
                            ),
                          ),
                          if (_selectedDob != null)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: mintAccent.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                '${_calculateAge(_selectedDob!)} yrs',
                                style: const TextStyle(
                                  color: mintAccent,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // 3. Gender Selection
                  Row(
                    children: const [
                      Text(
                        'Gender',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        ' *',
                        style: TextStyle(
                          color: DpcColors.accentNegative,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _genderOptions.map((option) {
                      final isSelected = _selectedGender == option;
                      return InkWell(
                        key: Key('gender_chip_$option'),
                        onTap: () {
                          setState(() {
                            _selectedGender = option;
                            _errorMessage = null;
                          });
                        },
                        borderRadius: BorderRadius.circular(10),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? mintAccent.withValues(alpha: 0.15)
                                : DpcColors.bgOled,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: isSelected
                                  ? mintAccent
                                  : DpcColors.surfaceBorder,
                              width: 1.2,
                            ),
                          ),
                          child: Text(
                            option,
                            style: TextStyle(
                              color: isSelected
                                  ? mintAccent
                                  : DpcColors.textSecondary,
                              fontSize: 12,
                              fontWeight: isSelected
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 24),

                  // 4. Save & Continue Action Button
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton(
                      key: const Key('save_profile_button'),
                      onPressed: isReady ? _handleSave : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: isReady
                            ? mintAccent
                            : DpcColors.surfaceTrack,
                        foregroundColor: isReady
                            ? Colors.black
                            : DpcColors.textMuted,
                        disabledBackgroundColor: DpcColors.surfaceTrack,
                        disabledForegroundColor: DpcColors.textMuted,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                          side: BorderSide(
                            color: isReady
                                ? mintAccent
                                : DpcColors.surfaceBorder,
                            width: 1,
                          ),
                        ),
                      ),
                      child: _isSaving
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: Colors.black,
                              ),
                            )
                          : const Text(
                              'Save & Continue',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
