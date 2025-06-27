import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:secuqr1/product_details_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'colors/appcolor.dart';
import 'detector_view.dart';
import 'profile.dart';
import 'painters/barcode_detector_painter.dart';
import 'history.dart';
import 'result_qr.dart';
import 'package:image/image.dart' as img;
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'main.dart'; // Adjust path based on your folder structure

class BarcodeScannerView extends StatefulWidget {
  const BarcodeScannerView({super.key});

  @override
  State<BarcodeScannerView> createState() => _BarcodeScannerViewState();
}

enum QRCodeState { waiting, scanning, successful }

class _BarcodeScannerViewState extends State<BarcodeScannerView> {
  final BarcodeScanner _barcodeScanner =
  BarcodeScanner(formats: [BarcodeFormat.qrCode]);
  bool _canProcess = true;
  bool _isBusy = false;
  CustomPaint? _customPaint;
  String? _text;
  CameraLensDirection _cameraLensDirection = CameraLensDirection.back;
  double _barcodeSize = 0;
  Size? _cameraSize;
  Timer? _captureTimer;
  Timer? _resetZoomTimer;
  bool _isCapturing = false;
  bool _isCameraInitialized = false;
  double lastX = 0, lastY = 0, lastZ = 0;
  double shakeThreshold = 15.0;
  bool isShaking = false;
  Uint8List? _croppedImageBytes;
  bool isDialogVisible = false;
  double currentZoomLevel = 1.0;
  DateTime? _lastQRCodeDetectedTime;
  bool _isReinitializing = false;
  StreamSubscription? _accelerometerSubscription;
  bool _isLoading = false;
  bool _cameraPause = false;
  late BuildContext loadingDialogContext;
  bool _isButtonDisabled = false;
  QRCodeState _qrCodeState = QRCodeState.waiting;
  String str3 = " ";
  int? _qrStatus;

  // Flags for focus & zoom
  bool _isFocusLocked = false;
  bool _isZoomDone = true;

  late CameraService _cameraService;
  CameraController? _cameraController;

  @override
  void initState() {
    super.initState();
    _resetState();
    _initializeGlobalCamera(); // Initialize global camera
    _startResetZoomTimer();
    _startAccelerometerListener();
  }

  void _resetState() {
    _canProcess = true;
    _isBusy = false;
    _customPaint = null;
    _text = null;
    _barcodeSize = 0; // Reset this
    _isCapturing = false;
    _isCameraInitialized = true;
    currentZoomLevel = 1.0;
    _isZoomDone = true;
    _isFocusLocked = false;
    _qrCodeState = QRCodeState.waiting;
    _isLoading = false;
    _cameraPause = false;
    isDialogVisible = false;
    _lastQRCodeDetectedTime = null;
  }

  Future<void> _initializeGlobalCamera() async {
    _cameraService = CameraService(); // Get singleton instance
    _cameraController = _cameraService.cameraController;
    enableStabilization();
    if (_cameraController != null &&
        _cameraController!.value.isInitialized) {
      setState(() {
        _isCameraInitialized = true;
      });
    } else {
      await _cameraService.initializeCamera();
      _cameraController!.setFlashMode(FlashMode.off);
      setState(() {
        _isCameraInitialized = true;
        _cameraController = _cameraService.cameraController;
      });
    }
  }

  bool _isDeviceStable(Rect barcodeRect, Size screenSize) {
    final bool isCentered = barcodeRect.center.dy > screenSize.height * 0.3 &&
        barcodeRect.center.dy < screenSize.height * 0.7 &&
        barcodeRect.center.dx > screenSize.width * 0.3 &&
        barcodeRect.center.dx < screenSize.width * 0.7;
    final bool isSizeGood = _barcodeSize > 10000 && _barcodeSize < 40000;
    return isCentered && isSizeGood && !isShaking;
  }

  Timer? _stabilityCheckTimer;
  void _startStabilityCheck(Rect barcodeRect, Size screenSize) {
    _stabilityCheckTimer?.cancel();
    _stabilityCheckTimer = Timer.periodic(const Duration(milliseconds: 50), (timer) {
      if (_isDeviceStable(barcodeRect, screenSize)) {
        _stabilityCheckTimer?.cancel();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_isCapturing) {
            _captureImage(barcodeRect); // Capture immediately
          }
        });
      }
    });
  }

  void _startAccelerometerListener() {
    final List<double> deltaHistory = [];
    const int windowSize = 15;
    _accelerometerSubscription = accelerometerEvents.listen((event) {
      if (!mounted) return;
      final double magnitude =
          event.x.abs() + event.y.abs() + event.z.abs();
      deltaHistory.add(magnitude);
      if (deltaHistory.length > windowSize) {
        deltaHistory.removeAt(0);
      }
      final avgMagnitude =
          deltaHistory.reduce((a, b) => a + b) / deltaHistory.length;
      final bool isShakingNow = avgMagnitude > shakeThreshold;
      if (isShakingNow != isShaking && mounted) {
        setState(() {
          isShaking = isShakingNow;
        });
        if (!isShaking) {
          _adjustZoomIfStable();
        }
      }
    });
  }

  Future<void> _adjustZoomIfStable() async {
    if (!isShaking &&
        _cameraController != null &&
        _cameraController!.value.isInitialized &&
        !_isZoomDone &&
        !_isCapturing) {
      final targetZoom = 1.3;
      if (currentZoomLevel < targetZoom) {
        setState(() => _isZoomDone = false);
        await _smoothZoomTo(targetZoom, MediaQuery.of(context).size);
        setState(() {
          _isZoomDone = true;
        });
      }
    }
  }

  Future<void> _adjustZoom(double barcodeSize, Rect barcodeBoundingBox,
      Size screenSize) async {
    if (barcodeSize >= 6000 || isShaking) return;
    double targetZoomLevel = 5.0 - ((barcodeSize / 125) * 0.0625);
    targetZoomLevel = targetZoomLevel.clamp(1.5, 4.0);

    bool nearEdge = barcodeBoundingBox.left < 50 ||
        barcodeBoundingBox.right > (screenSize.width - 50) ||
        barcodeBoundingBox.top < 50 ||
        barcodeBoundingBox.bottom > (screenSize.height - 50);
    if (nearEdge) {
      targetZoomLevel = targetZoomLevel.clamp(1.5, 3.0);
    }

    if (currentZoomLevel >= targetZoomLevel) return;

    setState(() {
      _isZoomDone = false;
    });

    await _smoothZoomTo(targetZoomLevel, screenSize);
    setState(() {
      _isZoomDone = true;
    });
  }

  Future<void> _smoothZoomTo(double targetZoomLevel, Size screenSize,
      {Duration duration = const Duration(milliseconds: 300)}) async {
    int steps = (duration.inMilliseconds / 16).round(); // ~60fps
    double zoomIncrement =
        (targetZoomLevel - currentZoomLevel) / steps;
    for (int i = 0; i < steps; i++) {
      if (isShaking) break;
      currentZoomLevel += zoomIncrement;
      currentZoomLevel = currentZoomLevel.clamp(1.0, 4.0);
      try {
        await _cameraController!.setZoomLevel(currentZoomLevel);
      } catch (e) {
        debugPrint("Zoom error: $e");
      }
      await Future.delayed(const Duration(milliseconds: 16));
    }
    await _cameraController!.setZoomLevel(currentZoomLevel);
  }

  void showTopSnackbar(BuildContext context, String message) {
    final overlay = Overlay.of(context);
    final overlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        top: MediaQuery.of(context).padding.top + 10,
        left: 20,
        right: 20,
        child: Material(
          color: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.6),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
          ),
        ),
      ),
    );
    overlay.insert(overlayEntry);
    Future.delayed(const Duration(seconds: 1), () {
      overlayEntry.remove();
    });
  }

  @override
  void dispose() {
    _captureTimer?.cancel();
    _resetZoomTimer?.cancel();
    _canProcess = false;
    _barcodeScanner.close();
    _accelerometerSubscription?.cancel();
    super.dispose();
  }

  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Stack(
          children: [
            _isCameraInitialized
                ? DetectorView(
              title: 'Barcode Scanner',
              customPaint: _customPaint,
              text: _text,
              onImage: (inputImage) {
                if (!isDialogVisible &&
                    !_isCapturing &&
                    !_isBusy) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!_isCapturing && !_isBusy) {
                      _processImage(inputImage, screenSize);
                    }
                  });
                }
              },
              initialCameraLensDirection: _cameraLensDirection,
              onCameraLensDirectionChanged: (value) =>
                  setState(() => _cameraLensDirection = value),
              qrCodeState: _qrCodeState,
            )
                : const Center(child: CircularProgressIndicator()),
            if (_isLoading)
              const Center(child: CircularProgressIndicator()),
          ],
        ),
      ),
      bottomNavigationBar: BottomAppBar(
        color: Colors.white,
        child: Container(
          height: 70,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              GestureDetector(
                onTap: () {
                  Navigator.pushAndRemoveUntil(
                    context,
                    PageRouteBuilder(
                      pageBuilder: (_, __, ___) => Scan_history_Page(),
                      transitionDuration: const Duration(milliseconds: 3),
                      transitionsBuilder: (_, animation, __, child) {
                        return FadeTransition(
                          opacity: animation,
                          child: child,
                        );
                      },
                    ),
                        (route) => false,
                  );
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(FontAwesomeIcons.clock),
                    Text("History", style: TextStyle(fontSize: 10)),
                  ],
                ),
              ),
              SizedBox(
                width: 48,
                height: 48,
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF0092B4),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: IconButton(
                    icon:
                    const Icon(Icons.qr_code_scanner, color: Colors.white),
                    onPressed: () {},
                  ),
                ),
              ),
              GestureDetector(
                onTap: () {
                  Navigator.pushAndRemoveUntil(
                    context,
                    PageRouteBuilder(
                      pageBuilder: (_, __, ___) => ProfileApp(),
                      transitionDuration: const Duration(milliseconds: 20),
                      transitionsBuilder: (_, animation, __, child) {
                        return FadeTransition(
                          opacity: animation,
                          child: child,
                        );
                      },
                    ),
                        (route) => false,
                  );
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(FontAwesomeIcons.link),
                    Text("Connect", style: TextStyle(fontSize: 10)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _processImage(InputImage inputImage, Size screenSize) async {
    if (!_canProcess || _isBusy || _isCapturing || _cameraPause) return;
    _isBusy = true;
    setState(() {
      _text = '';
    });
    try {
      final barcodes = await _barcodeScanner.processImage(inputImage);
      if (barcodes.isNotEmpty) {
        _cancelResetZoomTimer();
        _lastQRCodeDetectedTime = DateTime.now();
      }

      if (inputImage.metadata?.size != null &&
          inputImage.metadata?.rotation != null) {
        final painter = BarcodeDetectorPainter(
          barcodes,
          inputImage.metadata!.size!,
          inputImage.metadata!.rotation!,
          _cameraLensDirection,
              (size) {
            SchedulerBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                setState(() {
                  _barcodeSize = size;
                });
                final barcode = barcodes.first;
                final barcodeRect = barcode.boundingBox;
                if (_barcodeSize < 6000) {
                  _adjustZoom(size, barcodeRect, screenSize);
                } else if (_barcodeSize >= 6000) {
                  if (!_isCapturing &&
                      (_captureTimer == null || !_captureTimer!.isActive)) {
                    setState(() {
                      _qrCodeState = QRCodeState.scanning;
                    });
                    _startStabilityCheck(barcodeRect, screenSize);
                    _startCaptureTimer(barcodeRect);
                  }
                }
              }
            });
          },
          _cameraSize ?? Size.zero,
        );
        _customPaint = CustomPaint(painter: painter);
        if (barcodes.isNotEmpty && mounted) {
          setState(() {
            _qrCodeState = QRCodeState.scanning;
          });
        }
      }
    } catch (e) {
      debugPrint('Error processing image: $e');
    } finally {
      _isBusy = false;
      _checkQRCodeTimeout();
    }
  }

  void _checkQRCodeTimeout() {
    if (_lastQRCodeDetectedTime != null &&
        DateTime.now().difference(_lastQRCodeDetectedTime!).inMinutes >= 3) {
      _resetZoomLevel1();
    }
  }

  void _resetZoomLevel1() {
    if (currentZoomLevel != 1.0) {
      currentZoomLevel = 1.0;
      _cameraController?.setZoomLevel(currentZoomLevel);
    }
  }

  void _cancelResetZoomTimer() {
    _resetZoomTimer?.cancel();
  }

  void _startResetZoomTimer() {
    _resetZoomTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!_isCapturing) {
        _resetZoomLevel();
      }
    });
  }

  void _resetZoomLevel() async {
    setState(() {
      currentZoomLevel = 1.0;
    });
    if (_cameraController != null) {
      await _cameraController!.setZoomLevel(currentZoomLevel);
    }
  }

  void _startScanning() {
    _cameraController!.setFlashMode(FlashMode.off);
    _resetZoomLevel();
    if (_isLoading || _isReinitializing) return;
    setState(() {
      _isLoading = true;
      _isCapturing = false;
      isDialogVisible = false;
      _isZoomDone = true;
      _isReinitializing = false;
      _isButtonDisabled = false;
    });
    _captureTimer?.cancel();
    _resetZoomTimer?.cancel();
    _resetState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _resetFocus();
        _startResetZoomTimer();
        _cameraController?.resumePreview();
        setState(() {
          _isLoading = false;
          _isReinitializing = false;
          _cameraPause = false;
          _qrCodeState = QRCodeState.waiting;
        });
      }
    });
  }

  Future<void> _captureImage(Rect? barcodeRect) async {
    if (_cameraPause ||
        _isCapturing ||
        _cameraController == null ||
        !_cameraController!.value.isInitialized ||
        !_isZoomDone ||
        isShaking ||
        !mounted) {
      return;
    }

    try {
      if (isShaking) {
        showTopSnackbar(context, "Waiting for camera to stabilize...");
        return;
      }

      if (_barcodeSize > 43000) {
        if (mounted) {
          _cameraController?.setZoomLevel(currentZoomLevel - 0.5);
          showTopSnackbar(context,
              "Move your mobile slightly away from the QR code.");
        }
        return;
      }

      setState(() {
        _isCapturing = true;
        _customPaint = null;
      });

      await _setFixedFocus(barcodeRect);

      final XFile image = await _cameraController!.takePicture();
      final Uint8List imageBytes = await image.readAsBytes();

      final InputImage inputImage =
      InputImage.fromFilePath(image.path);
      final barcodes = await _barcodeScanner.processImage(inputImage);
      if (barcodes.isEmpty) {
        setState(() {
          _isCapturing = false;
          _barcodeSize = 0;
        });
        return;
      }

      final Barcode qrCode = barcodes.first;
      final Rect boundingBox = qrCode.boundingBox;

      await _cameraController?.pausePreview();

      final img.Image? originalImage = img.decodeImage(imageBytes);
      if (originalImage == null) {
        _startScanning();
        return;
      }

      final int cropX = boundingBox.left.toInt();
      final int cropY = boundingBox.top.toInt();
      final int cropWidth = boundingBox.width.toInt();
      final int cropHeight = boundingBox.height.toInt();

      final int adjustedX = cropX.clamp(0, originalImage.width - cropWidth);
      final int adjustedY = cropY.clamp(0, originalImage.height - cropHeight);

      final img.Image croppedImage = img.copyCrop(originalImage,
          x: adjustedX - 35,
          y: adjustedY - 35,
          width: cropWidth + 70,
          height: cropHeight + 70);

      final img.Image resizedImage =
      img.copyResize(croppedImage, width: 512, height: 512);

      final Uint8List pngData =
      Uint8List.fromList(img.encodePng(resizedImage));
      _croppedImageBytes = pngData;

      if (_croppedImageBytes != null && !isDialogVisible && mounted) {
        setState(() {
          isDialogVisible = true;
        });
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: buildCaptureDialog,
        );
      }
    } catch (e, stackTrace) {
      debugPrint('Error capturing image: $e\n$stackTrace');
    } finally {
      setState(() {
        _isCapturing = false;
        _cameraPause = false;
      });
      if (_cameraController != null &&
          !_cameraController!.value.isStreamingImages) {
        await _cameraController?.resumePreview();
      }
    }
  }

  Future<void> _setFixedFocus(Rect? barcodeRect) async {
    if (_cameraPause ||
        _cameraController == null ||
        !_cameraController!.value.isInitialized) return;
    try {
      Offset focusPoint = const Offset(0.5, 0.5); // Default center
      if (barcodeRect != null) {
        final previewSize = _cameraController!.value.previewSize;
        if (previewSize != null) {
          final centerX = (barcodeRect.left + barcodeRect.right) / 2;
          final centerY = (barcodeRect.top + barcodeRect.bottom) / 2;
          final normalizedX = centerX / previewSize.width;
          final normalizedY = centerY / previewSize.height;
          focusPoint = Offset(
            normalizedX.clamp(0.0, 1.0),
            normalizedY.clamp(0.0, 1.0),
          );
        }
      }
      await _cameraController!.setFocusPoint(focusPoint);
      await Future.delayed(const Duration(milliseconds: 150)); // Fast focus lock
    } catch (e) {
      debugPrint('Error setting fixed focus: $e');
    }
  }

  void _startCaptureTimer(Rect? barcodeRect) {
    _captureTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (_isCapturing || !_isZoomDone || isShaking || _cameraPause) return;
      if (_barcodeSize > 43000) {
        if (mounted) {
          showTopSnackbar(context,
              "Adjust your distance from the QR code for better clarity.");
        }
        _cameraController?.setZoomLevel(currentZoomLevel - 0.5);
        return;
      }
      _setFixedFocus(barcodeRect);
      _captureImage(barcodeRect);
    });
  }

  Future<String?> getAndroidId() async {
    final deviceInfo = DeviceInfoPlugin();
    final androidInfo = await deviceInfo.androidInfo;
    return androidInfo.id;
  }

  Future<void> sendImageToApi(Uint8List imageBytes) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => Dialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: const [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text("Validating...",
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
            ],
          ),
        ),
      ),
    );

    var uuid = Uuid();
    String sessId = uuid.v1();
    String uniqId = uuid.v1();
    String scndVal = str3;
    String latLong = await _getCurrentLocation();
    String mobiOs = await _getDeviceOS();
    String scndDtm =
    DateFormat("yyyy-MM-dd HH-mm-ss").format(DateTime.now());
    String origIp = await _getIpAddress();
    String? androidId = await getAndroidId();

    final url = Uri.parse('https://scnapi.secuqr.com/api/vldqr');
    final request = http.MultipartRequest('POST', url);
    request.headers.addAll({"X-API-Key": "SECUQR"});

    request.fields.addAll({
      "sess_id": sessId,
      "scnd_val": scndVal,
      "lat_long": latLong,
      "mobi_os": mobiOs,
      "uniq_id": uniqId,
      "email_id": "cmgxieavqh@SecuQR.com",
      "scnd_dtm": scndDtm,
      "orig_ip": origIp,
      "usr_fone": "+917658483796",
    });

    request.files.add(http.MultipartFile.fromBytes(
      'scnd_img',
      imageBytes,
      filename: 'scanned_image.png',
      contentType: MediaType('image', 'png'),
    ));

    try {
      final response = await request.send();
      final responseData = await http.Response.fromStream(response);
      Navigator.of(context, rootNavigator: true).pop();

      if (responseData.statusCode == 200) {
        final Map<String, dynamic> data = json.decode(responseData.body);
        final int status = data['status'] ?? -1;
        final Uint8List? binObjBytes = data['binobj'] != null
            ? base64Decode(data['binobj'])
            : null;
        String statusLabel = (status == 1)
            ? "Genuine"
            : (status == 0)
            ? "Counterfeit"
            : "Error";

        setState(() {
          _qrStatus = status;
        });

        if (binObjBytes != null) {
          await saveScanToSharedPreferences(
              statusLabel, scndDtm, binObjBytes);
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (BuildContext context) =>
                _buildResultContentDialog(context, binObjBytes),
          );
        } else if (status == 0) {
          await saveScanToSharedPreferences(
              statusLabel, scndDtm, imageBytes);
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (BuildContext context) =>
                _buildResultContentDialog(context, imageBytes),
          );
        } else {
          _showRetryDialog("Something went wrong. Please try again.");
        }
      } else {
        _showRetryDialog("Network issue detected. Please try again.");
      }
    } catch (e) {
      debugPrint('API Error: $e');
      Navigator.of(context, rootNavigator: true).pop();
      _showRetryDialog(
          "Unable to reach server. Please check internet connection.");
    }
  }

  Future<void> _resetFocus() async {
    if (_cameraController != null &&
        _cameraController!.value.isInitialized) {
      try {
        await Future.delayed(const Duration(milliseconds: 200));
        await _cameraController!
            .setFocusPoint(const Offset(0.5, 0.5)); // Center of screen
      } catch (e) {
        debugPrint("Failed to reset focus: $e");
      }
    }
  }

  Future<void> _showRetryDialog(String errorMessage) async {
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        title: const Text("Error"),
        content: Text(errorMessage),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context); // Close dialog
              _startScanning();
            },
            child: const Text("Retry"),
          )
        ],
      ),
    );
  }

  Widget buildCaptureDialog(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white,
      shape:
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      elevation: 5,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.memory(_croppedImageBytes!),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton(
                  onPressed: () {
                    Navigator.of(context).pop();
                    sendImageToApi(_croppedImageBytes!);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6)),
                    elevation: 0,
                  ),
                  child: const Text("OK"),
                ),
                const SizedBox(width: 10),
                ElevatedButton.icon(
                  onPressed: _isButtonDisabled
                      ? null
                      : () {
                    setState(() {
                      _isButtonDisabled = true;
                    });
                    Navigator.of(context).pop();
                    _startScanning();
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6)),
                    elevation: 0,
                  ),
                  icon: const Icon(Icons.camera_alt,
                      color: Color(0xFF0092B4)),
                  label: const Text("Scan Again"),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<String> _getCurrentLocation() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return "0.0,0.0";
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever) return "0.0,0.0";
    Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high);
    return "${position.latitude},${position.longitude}";
  }

  Future<String> _getDeviceOS() async {
    DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
    if (Platform.isAndroid) {
      AndroidDeviceInfo androidInfo = await deviceInfo.androidInfo;
      return "Android ${androidInfo.version.release}";
    } else if (Platform.isIOS) {
      IosDeviceInfo iosInfo = await deviceInfo.iosInfo;
      return "iOS ${iosInfo.systemVersion}";
    }
    return "Unknown";
  }

  Future<String> _getIpAddress() async {
    try {
      final response = await http.get(Uri.parse('https://api64.ipify.org ?format=json'));
      if (response.statusCode == 200) {
        return json.decode(response.body)['ip'] ?? "";
      }
    } catch (e) {
      debugPrint("IP fetch error: $e");
    }
    return "";
  }

  Widget _buildResultContentDialog(
      BuildContext context, Uint8List? qrImageBytes) {
    Color resultColor;
    IconData resultIcon;
    IconData resultIcon1 = FontAwesomeIcons.shield;
    String resultTitle;
    String resultMessage1;

    switch (_qrStatus) {
      case 1:
        resultColor = Colors.green;
        resultIcon = Icons.check_circle;
        resultTitle = "Genuine";
        resultMessage1 =
        "Your Product is Secured & Authenticated by SecuQR";
        break;
      case 0:
        resultColor = Colors.red;
        resultIcon = Icons.cancel;
        resultTitle = "Counterfeit";
        resultMessage1 = "Not an authenticated\n\tSecuQR product";
        break;
      default:
        resultColor = Colors.orange;
        resultIcon = Icons.error;
        resultTitle = "Error";
        resultMessage1 = "\tThis product is not\nRecognized by SecuQR";
        break;
    }

    return AlertDialog(
      backgroundColor: Colors.white,
      shape:
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      contentPadding: const EdgeInsets.all(16),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Stack(
                alignment: Alignment.center,
                children: [
                  Icon(resultIcon1, size: 60, color: resultColor),
                  Icon(resultIcon, color: Colors.white, size: 30),
                ],
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  resultTitle,
                  textAlign: TextAlign.left,
                  style: TextStyle(
                      fontSize: 25,
                      fontWeight: FontWeight.bold,
                      color: resultColor),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (qrImageBytes != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.memory(
                qrImageBytes,
                height: 200,
                width: 200,
                fit: BoxFit.cover,
              ),
            ),
          const SizedBox(height: 24),
          Text(
            resultMessage1,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 24),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 150,
                child: ElevatedButton(
                  onPressed: () {
                    // Navigate to ProductDetailsPage if needed
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0092B4),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                    padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
                  ),
                  child: const Text("Product Details",
                      style: TextStyle(fontSize: 15)),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: 150,
                child: ElevatedButton.icon(
                  onPressed: _isButtonDisabled
                      ? null
                      : () {
                    setState(() {
                      _isButtonDisabled = true;
                    });
                    Navigator.of(context).pop();
                    _startScanning();
                  },
                  label: const Text("Close", style: TextStyle(fontSize: 15)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.grey.shade200,
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                    padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> saveScanToSharedPreferences(
      String status, String dateTime, Uint8List image) async {
    final prefs = await SharedPreferences.getInstance();
    final historyList = prefs.getStringList('scanHistory') ?? [];
    ScanHistoryItem item =
    ScanHistoryItem(status: status, dateTime: dateTime, image: image);
    historyList.add(jsonEncode(item.toJson()));
    await prefs.setStringList('scanHistory', historyList);
  }
}

class ScanHistoryItem {
  final String status;
  final String dateTime;
  final Uint8List image;

  ScanHistoryItem(
      {required this.status,
        required this.dateTime,
        required this.image});

  Map<String, dynamic> toJson() => {
    'status': status,
    'dateTime': dateTime,
    'image': base64Encode(image),
  };

  factory ScanHistoryItem.fromJson(Map<String, dynamic> json) {
    return ScanHistoryItem(
      status: json['status'],
      dateTime: json['dateTime'],
      image: base64Decode(json['image']),
    );
  }
}
