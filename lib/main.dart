import 'dart:ui' as ui;
import 'package:camera/camera.dart';
import 'package:e_signature/Views/e_signature.dart';
import 'package:flutter/material.dart';



Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Fetch the list of available cameras
  try {
    cameras = await availableCameras();
  } catch (e) {
    print('Error fetching cameras: $e');
    cameras = []; // Initialize with an empty list if fetching fails
  }

  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SfSignaturePad Demo',
      home: ESignatureFlutter(),
    );
  }
}
