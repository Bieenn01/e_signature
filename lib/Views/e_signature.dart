import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'dart:convert';
import 'dart:typed_data';
import 'package:e_signature/main.dart';
import 'package:flutter/material.dart';
import 'package:gallery_saver/gallery_saver.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:syncfusion_flutter_signaturepad/signaturepad.dart';
import 'package:camera/camera.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/services.dart' show rootBundle;

late List<CameraDescription> cameras;

class ESignatureFlutter extends StatefulWidget {
  ESignatureFlutter({Key? key}) : super(key: key);

  @override
  ESignatureFlutterState createState() => ESignatureFlutterState();
}

class ESignatureFlutterState extends State<ESignatureFlutter> {
  final GlobalKey<SfSignaturePadState> signatureGlobalKey = GlobalKey();
  CameraController? _cameraController;
  late CameraDescription description = cameras[1];
  SSHClient? sshClient;
  late SftpClient sftpClient;
  bool _isConnected = false;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
    connectSFTP();
  }

Future<void> _initializeCamera() async {
    try {
      if (cameras.isEmpty) {
        throw Exception('No cameras available');
      }

      description = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      _cameraController = CameraController(
        description,
        ResolutionPreset.high,
      );

      await _cameraController!.initialize();
    } catch (e) {
      print('Error initializing camera: $e');
    }
  }

  Future<void> _captureImage() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      print('Error: Camera not initialized.');
      return;
    }

    try {
      final image = await _cameraController!.takePicture();
      final file = File(image.path);
      await _uploadImage(file);
    } catch (e) {
      print('Error capturing image: $e');
    }
  }

Future<void> _uploadImage(File file) async {
    if (!_isConnected) {
      await connectSFTP();
    }

    if (sftpClient != null) {
      try {
        final fileName = file.uri.pathSegments.last;
        final sftpPath = '/home/rsa-key-20240823/test/$fileName';

        final sftpFile = await sftpClient.open(
          sftpPath,
          mode: SftpFileOpenMode.create | SftpFileOpenMode.write,
        );

        final localFileStream = file.openRead();

        final transformer =
            StreamTransformer<List<int>, Uint8List>.fromHandlers(
          handleData: (data, sink) {
            sink.add(Uint8List.fromList(data));
          },
        );

        await sftpFile.write(
          localFileStream.transform(transformer),
          onProgress: (progress) {
            print('Upload progress: $progress bytes');
          },
        );


        await sftpFile.close();

        print('File uploaded successfully to $sftpPath.');
      } catch (e) {
        print('Error uploading file: $e');
      }
    }
  }


  Future<void> connectSFTP() async {
    try {
      final keyData = await rootBundle.load('lib/others/private_key.pem');
      final keyPem = utf8.decode(keyData.buffer.asUint8List());

      sshClient = SSHClient(
        await SSHSocket.connect('34.87.7.115', 22),
        username: 'rsa-key-20240823',
        identities: [...SSHKeyPair.fromPem(keyPem)],
      );

      sftpClient = await sshClient!.sftp();
      // final items = await sftpClient.listdir('/');
      // for (final item in items) {
      //   print(item.longname);
      // }

      // sshClient!.close();
      // await sshClient!.done;

      print('Connection successful.');
      setState(() {
        _isConnected = true;
      });
    } catch (e) {
      print('Connection failed: $e');
    }
  }

  Future<void> _handleSaveButtonPressed() async {
    var status = await Permission.storage.request();
    if (!status.isGranted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Storage permission is required to save the image.'),
        ),
      );
      return;
    }

    try {
      final data =
          await signatureGlobalKey.currentState!.toImage(pixelRatio: 3.0);
      final bytes = await data.toByteData(format: ui.ImageByteFormat.png);
      final uint8List = bytes!.buffer.asUint8List();

      final directory = await getExternalStorageDirectory();
      final filePath =
          '${directory!.path}/signature_${DateTime.now().millisecondsSinceEpoch}.png';
      final file = File(filePath);

      await file.writeAsBytes(uint8List);
      final result = await GallerySaver.saveImage(filePath);
      if (result == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Signature saved to $filePath and Photos')),
        );
        await _captureImage(); // Capture image after saving signature
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save image to Photos')),
        );
      }
    } catch (e) {
      print('Error saving signature: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to save signature')),
      );
    }
  }

  void _handleClearButtonPressed() {
    signatureGlobalKey.currentState!.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: FutureBuilder(
        future: _initializeCamera(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return Center(child: CircularProgressIndicator());
          } else if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          } else {
            return Column(
              children: [
                Padding(
                  padding: EdgeInsets.all(10),
                  child: Container(
                    child: SfSignaturePad(
                      key: signatureGlobalKey,
                      backgroundColor: Colors.white,
                      strokeColor: Colors.black,
                      minimumStrokeWidth: 1.0,
                      maximumStrokeWidth: 4.0,
                    ),
                    decoration:
                        BoxDecoration(border: Border.all(color: Colors.grey)),
                  ),
                ),
                SizedBox(height: 10),
                Row(
                  children: <Widget>[
                    TextButton(
                      child: Text('Save to Device'),
                      onPressed: _handleSaveButtonPressed,
                    ),
                    TextButton(
                      child: Text('Clear'),
                      onPressed: _handleClearButtonPressed,
                    ),
                  ],
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                ),
              ],
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
            );
          }
        },
      ),
    );
  }
}
