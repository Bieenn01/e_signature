import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:gallery_saver/gallery_saver.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:syncfusion_flutter_signaturepad/signaturepad.dart';
import 'package:camera/camera.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;

late List<CameraDescription> cameras;

class ESignatureFlutter extends StatefulWidget {
  ESignatureFlutter({Key? key}) : super(key: key);

  @override
  ESignatureFlutterState createState() => ESignatureFlutterState();
}

class ESignatureFlutterState extends State<ESignatureFlutter> {
  final GlobalKey<SfSignaturePadState> signatureGlobalKey = GlobalKey();
  final TextEditingController _nameController = TextEditingController();
  CameraController? _cameraController;
  late CameraDescription description = cameras[1];
  SSHClient? sshClient;
  late SftpClient sftpClient;
  bool _isConnected = false;
  bool _isUploading = false;
  bool _isSaving = false;

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

  Future<void> _captureAndUploadImage() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      print('Error: Camera not initialized.');
      return;
    }

    setState(() {
      _isUploading = true;
    });

    try {
      final image = await _cameraController!.takePicture();
      final file = File(image.path);

      // Load the signature image
      final signatureData =
          await signatureGlobalKey.currentState!.toImage(pixelRatio: 3.0);
      final signatureBytes =
          await signatureData.toByteData(format: ui.ImageByteFormat.png);
      final signatureUint8List = signatureBytes!.buffer.asUint8List();

      // Get the name from the input field
      final name = _nameController.text;

      // Merge images
      final mergedImage = await _mergeImages(file, signatureUint8List, name);

      // Save merged image to a file
      final directory = await getTemporaryDirectory();
      final mergedImagePath =
          '${directory.path}/face_with_e-signature_${DateTime.now().millisecondsSinceEpoch}.png';
      final mergedFile = File(mergedImagePath);
      await mergedFile.writeAsBytes(mergedImage);

      // Upload the merged image
      await _uploadImage(mergedFile);

      print('Merged image uploaded successfully.');
    } catch (e) {
      print('Error capturing or uploading image: $e');
    } finally {
      setState(() {
        _isUploading = false;
      });
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

    setState(() {
      _isSaving = true;
    });

    try {
      // Save signature only
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
        await _captureAndUploadImage(); // Capture and upload merged image
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
    } finally {
      setState(() {
        _isSaving = false;
      });
    }
  }

Future<Uint8List> _mergeImages(
      File imageFile, Uint8List signatureBytes, String name) async {
    final baseImage = img.decodeImage(imageFile.readAsBytesSync())!;
    final signatureImage = img.decodeImage(signatureBytes)!;

    const topMargin = 20;

    final mergedImageWidth = baseImage.width;
    final mergedImageHeight =
        signatureImage.height + baseImage.height + topMargin;

    final mergedImage =
        img.Image(width: mergedImageWidth, height: mergedImageHeight);

    final xOffsetSignature =
        (mergedImageWidth - signatureImage.width) ~/ 50; 
    final yOffsetSignature = 0;

    img.compositeImage(mergedImage, signatureImage,
        dstX: xOffsetSignature, dstY: yOffsetSignature);

    final xOffsetBase =
        (mergedImageWidth - baseImage.width) ~/ 2; 
    final yOffsetBase = signatureImage.height + topMargin;

    img.compositeImage(mergedImage, baseImage,
        dstX: xOffsetBase, dstY: yOffsetBase);

    final nameText = name;

    final font = img.arial24;

    final nameX = 20;
    final nameY = 20;

    img.drawString(mergedImage, nameText,
        font: font,
        x: nameX,
        y: nameY,
        color: img.ColorFloat64.rgb(139, 0, 0)); // Color: Dark Red

    final mergedImageBytes = img.encodePng(mergedImage);
    return Uint8List.fromList(mergedImageBytes);
  }

  void _handleClearButtonPressed() {
    signatureGlobalKey.currentState!.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('ESignature Flutter'),
        backgroundColor: Colors.blueAccent,
      ),
      body: Center(
        child: OrientationBuilder(
          builder: (context, orientation) {
            // Use MediaQuery to get screen dimensions
            final screenSize = MediaQuery.of(context).size;
            final isLandscape = orientation == Orientation.landscape;

            return Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                children: [
                  // Text field for name input
                  TextField(
                    controller: _nameController,
                    decoration: InputDecoration(
                      labelText: 'Enter your name',
                      border: OutlineInputBorder(),
                    ),
                    textCapitalization: TextCapitalization.words,
                  ),
                  SizedBox(height: 20),

                  // Signature Pad with fixed height and flexible width
                  Container(
                    width:
                        isLandscape ? screenSize.width * 0.9 : screenSize.width,
                    height: isLandscape
                        ? screenSize.height * 0.4
                        : screenSize.height * 0.3,
                    padding: const EdgeInsets.all(10.0),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey),
                      borderRadius: BorderRadius.circular(8.0),
                    ),
                    child: SfSignaturePad(
                      key: signatureGlobalKey,
                      backgroundColor: Colors.white,
                      strokeColor: Colors.black,
                      minimumStrokeWidth: 1.0,
                      maximumStrokeWidth: 4.0,
                    ),
                  ),
                  SizedBox(height: 20),
                  _isSaving
                      ? CircularProgressIndicator()
                      : Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: <Widget>[
                            ElevatedButton(
                              onPressed: _handleSaveButtonPressed,
                              child: Text('Save to Device'),
                            ),
                            ElevatedButton(
                              onPressed: _handleClearButtonPressed,
                              child: Text('Clear'),
                            ),
                          ],
                        ),
                  SizedBox(height: 20),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
