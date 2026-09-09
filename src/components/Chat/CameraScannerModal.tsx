/**
 * @license
 * SPDX-License-Identifier: Apache-2.0
 */

import React, { useState, useRef, useEffect, useCallback } from 'react';
import { motion, AnimatePresence } from 'motion/react';
import { Camera, QrCode, X, SwitchCamera, Image as ImageIcon, Sparkles, CheckCircle2, Bot, AlertCircle, Flashlight } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Toast } from '@capacitor/toast';
import jsQR from 'jsqr';

interface CameraScannerModalProps {
  isOpen: boolean;
  onClose: () => void;
  onCaptureImage: (dataUrl: string) => void;
  onScanTokenSuccess: (token: string) => void;
  initialMode?: 'camera' | 'scanner';
}

export const CameraScannerModal: React.FC<CameraScannerModalProps> = ({
  isOpen,
  onClose,
  onCaptureImage,
  onScanTokenSuccess,
  initialMode = 'camera',
}) => {
  const [mode, setMode] = useState<'camera' | 'scanner'>(initialMode);
  const [facingMode, setFacingMode] = useState<'environment' | 'user'>('environment');
  const [hasCameraPermission, setHasCameraPermission] = useState<boolean | null>(null);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);
  const [isScanning, setIsScanning] = useState<boolean>(false);
  const [scannedSuccessToken, setScannedSuccessToken] = useState<string | null>(null);
  const [flashOn, setFlashOn] = useState(false);

  const videoRef = useRef<HTMLVideoElement | null>(null);
  const canvasRef = useRef<HTMLCanvasElement | null>(null);
  const streamRef = useRef<MediaStream | null>(null);
  const animFrameIdRef = useRef<number | null>(null);
  const fileInputRef = useRef<HTMLInputElement | null>(null);

  // Sync initial mode
  useEffect(() => {
    if (isOpen) {
      setMode(initialMode);
      setScannedSuccessToken(null);
      setErrorMessage(null);
    }
  }, [isOpen, initialMode]);

  // Clean stream
  const stopStream = useCallback(() => {
    if (animFrameIdRef.current) {
      cancelAnimationFrame(animFrameIdRef.current);
      animFrameIdRef.current = null;
    }
    if (streamRef.current) {
      streamRef.current.getTracks().forEach((track) => track.stop());
      streamRef.current = null;
    }
  }, []);

  // Parse QR content to extract agent token
  const parseTokenFromQR = (data: string): string | null => {
    if (!data) return null;
    const cleanData = data.trim();

    // 1. Check if URL containing ?agentToken= or ?token=
    try {
      if (cleanData.startsWith('http://') || cleanData.startsWith('https://')) {
        const url = new URL(cleanData);
        const tokenInUrl = url.searchParams.get('agentToken') || url.searchParams.get('token');
        if (tokenInUrl) return tokenInUrl.trim();
      }
    } catch (_) {}

    // 2. Check query string format: agentToken=...
    const matchParam = cleanData.match(/(?:agentToken|token)=([a-zA-Z0-9_\-]+)/i);
    if (matchParam && matchParam[1]) {
      return matchParam[1].trim();
    }

    // 3. Check JSON format: {"token": "..."}
    if (cleanData.startsWith('{') && cleanData.endsWith('}')) {
      try {
        const parsed = JSON.parse(cleanData);
        if (parsed.agentToken || parsed.token) {
          return (parsed.agentToken || parsed.token).trim();
        }
      } catch (_) {}
    }

    // 4. Check standard token patterns: token:xxx or agent:xxx or ag_xxx
    if (/^(token|agent):/i.test(cleanData)) {
      return cleanData.replace(/^(token|agent):/i, '').trim();
    }

    // 5. If it's a reasonably sized alphanumeric token string (e.g. agent_xxxx or custom string)
    if (/^[a-zA-Z0-9_\-]{4,64}$/.test(cleanData)) {
      return cleanData;
    }

    return null;
  };

  // Start Camera Stream
  const startCamera = useCallback(async () => {
    stopStream();
    setErrorMessage(null);

    try {
      const constraints: MediaStreamConstraints = {
        video: {
          facingMode: { ideal: facingMode },
          width: { ideal: 9248, max: 9248 },
          height: { ideal: 6930, max: 6930 },
        },
        audio: false,
      };

      const stream = await navigator.mediaDevices.getUserMedia(constraints);
      streamRef.current = stream;

      if (videoRef.current) {
        videoRef.current.srcObject = stream;
        videoRef.current.setAttribute('playsinline', 'true');
        await videoRef.current.play();
        setHasCameraPermission(true);
      }
    } catch (err: any) {
      console.error('Camera access failed:', err);
      setHasCameraPermission(false);
      setErrorMessage(
        err.name === 'NotAllowedError'
          ? '请在浏览器设置中允许相机访问权限'
          : '无法启动相机，请确认设备摄像头未被其他应用占用'
      );
    }
  }, [facingMode, stopStream]);

  // Start / Stop Video stream on Open/Close
  useEffect(() => {
    if (isOpen) {
      startCamera();
    } else {
      stopStream();
    }
    return () => {
      stopStream();
    };
  }, [isOpen, startCamera, stopStream]);

  // Handle successful QR detection
  const handleDetectedToken = useCallback((detectedToken: string) => {
    setScannedSuccessToken(detectedToken);
    
    // Play vibration & feedback
    if (typeof navigator !== 'undefined' && 'vibrate' in navigator) {
      try {
        navigator.vibrate([100, 50, 100]);
      } catch (_) {}
    }

    Toast.show({ text: `🎉 扫码成功！已连接本地电脑 Agent` });
    
    setTimeout(() => {
      onScanTokenSuccess(detectedToken);
      onClose();
    }, 900);
  }, [onClose, onScanTokenSuccess]);

  // Continuous Scan Loop for Scanner Mode
  useEffect(() => {
    if (!isOpen || mode !== 'scanner' || !hasCameraPermission || scannedSuccessToken) {
      if (animFrameIdRef.current) {
        cancelAnimationFrame(animFrameIdRef.current);
        animFrameIdRef.current = null;
      }
      setIsScanning(false);
      return;
    }

    setIsScanning(true);

    const scanFrame = () => {
      if (videoRef.current && videoRef.current.readyState === videoRef.current.HAVE_ENOUGH_DATA) {
        const video = videoRef.current;
        let canvas = canvasRef.current;
        if (!canvas) {
          canvas = document.createElement('canvas');
          canvasRef.current = canvas;
        }

        canvas.width = video.videoWidth;
        canvas.height = video.videoHeight;
        const ctx = canvas.getContext('2d', { willReadFrequently: true });
        
        if (ctx && canvas.width > 0 && canvas.height > 0) {
          ctx.drawImage(video, 0, 0, canvas.width, canvas.height);
          const imageData = ctx.getImageData(0, 0, canvas.width, canvas.height);
          
          try {
            const code = jsQR(imageData.data, imageData.width, imageData.height, {
              inversionAttempts: 'dontInvert',
            });

            if (code && code.data) {
              const token = parseTokenFromQR(code.data);
              if (token) {
                handleDetectedToken(token);
                return;
              }
            }
          } catch (e) {
            // ignore scan frame error
          }
        }
      }

      animFrameIdRef.current = requestAnimationFrame(scanFrame);
    };

    animFrameIdRef.current = requestAnimationFrame(scanFrame);

    return () => {
      if (animFrameIdRef.current) {
        cancelAnimationFrame(animFrameIdRef.current);
        animFrameIdRef.current = null;
      }
    };
  }, [isOpen, mode, hasCameraPermission, scannedSuccessToken, handleDetectedToken]);

  // Capture Photo
  const handleCapture = () => {
    if (!videoRef.current) return;
    const video = videoRef.current;
    const canvas = document.createElement('canvas');
    canvas.width = video.videoWidth || 1920;
    canvas.height = video.videoHeight || 1080;
    const ctx = canvas.getContext('2d');
    if (!ctx) return;

    // Flip horizontally if front camera
    if (facingMode === 'user') {
      ctx.translate(canvas.width, 0);
      ctx.scale(-1, 1);
    }
    ctx.drawImage(video, 0, 0, canvas.width, canvas.height);
    const dataUrl = canvas.toDataURL('image/jpeg', 0.98);

    // Also check if the photo contains a QR code
    try {
      const imgData = ctx.getImageData(0, 0, canvas.width, canvas.height);
      const code = jsQR(imgData.data, imgData.width, imgData.height);
      if (code && code.data) {
        const token = parseTokenFromQR(code.data);
        if (token) {
          handleDetectedToken(token);
          return;
        }
      }
    } catch (_) {}

    onCaptureImage(dataUrl);
    onClose();
  };

  // Upload Photo from File Input
  const handleFileSelect = (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;

    const reader = new FileReader();
    reader.onload = (event) => {
      const dataUrl = event.target?.result as string;
      if (!dataUrl) return;

      // Detect QR code in uploaded image
      const img = new window.Image();
      img.onload = () => {
        const canvas = document.createElement('canvas');
        canvas.width = img.width;
        canvas.height = img.height;
        const ctx = canvas.getContext('2d');
        if (ctx) {
          ctx.drawImage(img, 0, 0);
          const imgData = ctx.getImageData(0, 0, canvas.width, canvas.height);
          const code = jsQR(imgData.data, imgData.width, imgData.height);
          if (code && code.data) {
            const token = parseTokenFromQR(code.data);
            if (token) {
              handleDetectedToken(token);
              return;
            }
          }
        }
        onCaptureImage(dataUrl);
        onClose();
      };
      img.src = dataUrl;
    };
    reader.readAsDataURL(file);
    if (e.target) e.target.value = '';
  };

  // Toggle Torch/Flashlight
  const toggleFlashlight = async () => {
    if (!streamRef.current) return;
    const track = streamRef.current.getVideoTracks()[0];
    if (!track) return;

    try {
      const capabilities: any = track.getCapabilities ? track.getCapabilities() : {};
      if (capabilities.torch) {
        const nextState = !flashOn;
        await (track as any).applyConstraints({
          advanced: [{ torch: nextState }]
        });
        setFlashOn(nextState);
      } else {
        Toast.show({ text: '当前设备不支持补光灯' });
      }
    } catch (e) {
      console.warn('Flashlight error:', e);
    }
  };

  if (!isOpen) return null;

  return (
    <AnimatePresence>
      <motion.div
        initial={{ opacity: 0 }}
        animate={{ opacity: 1 }}
        exit={{ opacity: 0 }}
        className="fixed inset-0 z-50 bg-black flex flex-col justify-between overflow-hidden select-none"
      >
        {/* Top Floating Header & Mode Switcher */}
        <div className="absolute top-0 inset-x-0 z-20 flex items-center justify-between p-4 bg-gradient-to-b from-black/80 via-black/40 to-transparent pt-safe">
          <Button
            type="button"
            variant="ghost"
            size="icon"
            onClick={onClose}
            className="w-10 h-10 rounded-full bg-black/40 text-white backdrop-blur-md border border-white/10 hover:bg-black/60 active:scale-95"
          >
            <X size={20} />
          </Button>

          {/* Mode Pill Switcher */}
          <div className="flex items-center gap-1 p-1 bg-black/60 backdrop-blur-md rounded-full border border-white/15">
            <button
              type="button"
              onClick={() => setMode('camera')}
              className={`flex items-center gap-1.5 px-3 py-1.5 rounded-full text-xs font-medium transition-all ${
                mode === 'camera'
                  ? 'bg-white text-black font-semibold shadow-md'
                  : 'text-white/70 hover:text-white'
              }`}
            >
              <Camera size={14} />
              <span>拍照对话</span>
            </button>
            <button
              type="button"
              onClick={() => setMode('scanner')}
              className={`flex items-center gap-1.5 px-3 py-1.5 rounded-full text-xs font-medium transition-all ${
                mode === 'scanner'
                  ? 'bg-primary text-black font-semibold shadow-[0_0_12px_rgba(0,210,255,0.4)]'
                  : 'text-white/70 hover:text-white'
              }`}
            >
              <QrCode size={14} />
              <span>扫码连电脑</span>
            </button>
          </div>

          {/* Torch button */}
          <Button
            type="button"
            variant="ghost"
            size="icon"
            onClick={toggleFlashlight}
            className={`w-10 h-10 rounded-full text-white backdrop-blur-md border border-white/10 active:scale-95 ${
              flashOn ? 'bg-amber-400 text-black shadow-[0_0_10px_#fbbf24]' : 'bg-black/40 hover:bg-black/60'
            }`}
          >
            <Flashlight size={18} />
          </Button>
        </div>

        {/* Camera Live Viewfinder */}
        <div className="relative flex-1 w-full h-full flex items-center justify-center bg-black overflow-hidden">
          <video
            ref={videoRef}
            autoPlay
            playsInline
            muted
            className={`w-full h-full object-cover ${facingMode === 'user' ? 'scale-x-[-1]' : ''}`}
          />

          {/* Scanner Overlay Visuals */}
          {mode === 'scanner' && (
            <div className="absolute inset-0 flex flex-col items-center justify-center pointer-events-none p-6">
              {/* Semi-transparent mask surrounding cutout */}
              <div className="relative w-64 h-64 sm:w-72 sm:h-72 rounded-3xl border-2 border-primary/60 shadow-[0_0_0_9999px_rgba(0,0,0,0.6)] flex items-center justify-center overflow-hidden">
                {/* 4 Corner Bracket accents */}
                <div className="absolute top-2 left-2 w-6 h-6 border-t-4 border-l-4 border-primary rounded-tl-lg" />
                <div className="absolute top-2 right-2 w-6 h-6 border-t-4 border-r-4 border-primary rounded-tr-lg" />
                <div className="absolute bottom-2 left-2 w-6 h-6 border-b-4 border-l-4 border-primary rounded-bl-lg" />
                <div className="absolute bottom-2 right-2 w-6 h-6 border-b-4 border-r-4 border-primary rounded-br-lg" />

                {/* Animated Scanning Laser Line */}
                <motion.div
                  animate={{ y: [-110, 110, -110] }}
                  transition={{ duration: 2.2, repeat: Infinity, ease: 'easeInOut' }}
                  className="w-full h-0.5 bg-gradient-to-r from-transparent via-cyan-400 to-transparent shadow-[0_0_15px_#22d3ee]"
                />

                {/* Scanned success animation */}
                {scannedSuccessToken && (
                  <motion.div
                    initial={{ scale: 0.5, opacity: 0 }}
                    animate={{ scale: 1, opacity: 1 }}
                    className="absolute inset-0 bg-emerald-500/80 backdrop-blur-sm flex flex-col items-center justify-center text-white p-4"
                  >
                    <CheckCircle2 size={48} className="text-white animate-bounce mb-2" />
                    <span className="font-bold text-sm">配对成功！</span>
                    <span className="text-[11px] opacity-90 font-mono mt-1">Token: {scannedSuccessToken}</span>
                  </motion.div>
                )}
              </div>

              {/* Instructions */}
              <div className="mt-8 text-center bg-black/60 backdrop-blur-md px-4 py-2 rounded-2xl border border-white/10 max-w-xs">
                <p className="text-xs text-white/90 font-medium">对准电脑终端中的配对二维码</p>
                <p className="text-[10px] text-white/50 mt-0.5 font-mono">或运行 deepseek_bridge.py 打印的码</p>
              </div>
            </div>
          )}

          {/* Error Message Display */}
          {errorMessage && (
            <div className="absolute inset-0 bg-black/90 flex flex-col items-center justify-center p-6 text-center z-30">
              <AlertCircle size={40} className="text-amber-400 mb-3" />
              <p className="text-sm font-semibold text-white mb-2">{errorMessage}</p>
              <Button
                type="button"
                onClick={startCamera}
                className="mt-3 rounded-full bg-primary text-black font-semibold text-xs px-6"
              >
                重试开启相机
              </Button>
            </div>
          )}
        </div>

        {/* Bottom Floating Control Bar */}
        <div className="absolute bottom-0 inset-x-0 z-20 p-6 bg-gradient-to-t from-black/90 via-black/50 to-transparent flex items-center justify-around pb-safe">
          {/* Album / File Upload */}
          <div className="flex flex-col items-center gap-1">
            <Button
              type="button"
              variant="ghost"
              size="icon"
              onClick={() => fileInputRef.current?.click()}
              className="w-12 h-12 rounded-full bg-white/15 backdrop-blur-md text-white border border-white/10 hover:bg-white/25 active:scale-90 transition-all"
            >
              <ImageIcon size={22} />
            </Button>
            <span className="text-[10px] text-white/70 font-medium">相册导入</span>
            <input
              type="file"
              ref={fileInputRef}
              accept="image/*"
              className="hidden"
              onChange={handleFileSelect}
            />
          </div>

          {/* Main Action Button (Capture in camera mode / Scan status in scan mode) */}
          {mode === 'camera' ? (
            <button
              type="button"
              onClick={handleCapture}
              className="relative w-20 h-20 rounded-full border-4 border-white flex items-center justify-center p-1.5 active:scale-95 transition-all shadow-[0_0_20px_rgba(255,255,255,0.3)]"
            >
              <div className="w-full h-full bg-white rounded-full transition-transform active:scale-90" />
            </button>
          ) : (
            <div className="flex flex-col items-center">
              <div className="w-16 h-16 rounded-full bg-primary/20 border-2 border-primary flex items-center justify-center text-primary shadow-[0_0_20px_rgba(0,210,255,0.3)] animate-pulse">
                <Bot size={28} />
              </div>
              <span className="text-[10px] text-primary font-medium mt-1">自动识别中...</span>
            </div>
          )}

          {/* Switch Camera Button */}
          <div className="flex flex-col items-center gap-1">
            <Button
              type="button"
              variant="ghost"
              size="icon"
              onClick={() => setFacingMode((prev) => (prev === 'environment' ? 'user' : 'environment'))}
              className="w-12 h-12 rounded-full bg-white/15 backdrop-blur-md text-white border border-white/10 hover:bg-white/25 active:scale-90 transition-all"
            >
              <SwitchCamera size={22} />
            </Button>
            <span className="text-[10px] text-white/70 font-medium">翻转镜头</span>
          </div>
        </div>
      </motion.div>
    </AnimatePresence>
  );
};
