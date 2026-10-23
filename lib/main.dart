import 'dart:async';

import 'package:flutter/material.dart';
import 'package:school_erp_teachers/firebase_options.dart';
import 'package:school_erp_mobile_shared/school_erp_mobile_shared.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  unawaited(launchSchoolErpApp(role: MobileRole.teacher, firebaseOptions: DefaultFirebaseOptions.currentPlatform));
}
