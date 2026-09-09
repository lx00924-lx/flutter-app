/**
 * @license
 * SPDX-License-Identifier: Apache-2.0
 */

import { useState, useCallback, useEffect, useRef } from 'react';
import { VoiceRecorder } from 'capacitor-voice-recorder';

export const MAX_RECORDING_SECONDS = 60;

export function useVoiceRecorder() {
  const [isRecording, setIsRecording] = useState(false);
  const [audioUrl, setAudioUrl] = useState<string | null>(null);
  const [duration, setDuration] = useState(0);

  const durationTimerRef = useRef<NodeJS.Timeout | null>(null);
  const isRecordingRef = useRef(false);

  useEffect(() => {
    // Request permissions on mount
    VoiceRecorder.requestAudioRecordingPermission().catch(() => {});
  }, []);

  const clearTimer = useCallback(() => {
    if (durationTimerRef.current) {
      clearInterval(durationTimerRef.current);
      durationTimerRef.current = null;
    }
  }, []);

  const stopRecording = useCallback(async () => {
    if (!isRecordingRef.current) return;
    clearTimer();
    isRecordingRef.current = false;

    try {
      const result = await VoiceRecorder.stopRecording();
      setIsRecording(false);
      
      if (result.value && result.value.recordDataBase64) {
        // Create a data URL from base64
        const mimeType = result.value.mimeType || 'audio/webm';
        const dataUrl = `data:${mimeType};base64,${result.value.recordDataBase64}`;
        setAudioUrl(dataUrl);
      }
    } catch (err) {
      console.error('Failed to stop recording', err);
      setIsRecording(false);
    }
  }, [clearTimer]);

  const startRecording = useCallback(async () => {
    try {
      const { value } = await VoiceRecorder.canDeviceVoiceRecord();
      if (!value) {
        console.error('This device cannot record voice');
        return;
      }

      const { value: hasPermission } = await VoiceRecorder.hasAudioRecordingPermission();
      if (!hasPermission) {
        const { value: requested } = await VoiceRecorder.requestAudioRecordingPermission();
        if (!requested) {
          console.error('Permission denied');
          return;
        }
      }

      await VoiceRecorder.startRecording();
      isRecordingRef.current = true;
      setIsRecording(true);
      setAudioUrl(null);
      setDuration(0);

      clearTimer();
      let currentSeconds = 0;
      durationTimerRef.current = setInterval(() => {
        currentSeconds += 1;
        setDuration(currentSeconds);

        // 60秒上限自动停止
        if (currentSeconds >= MAX_RECORDING_SECONDS) {
          stopRecording();
        }
      }, 1000);

    } catch (err) {
      console.error('Failed to start recording', err);
      isRecordingRef.current = false;
      setIsRecording(false);
      clearTimer();
    }
  }, [clearTimer, stopRecording]);

  useEffect(() => {
    return () => {
      clearTimer();
      // Emergency stop on unmount
      VoiceRecorder.getCurrentStatus().then(({ status }) => {
        if (status === 'RECORDING') {
          VoiceRecorder.stopRecording().catch(() => {});
        }
      }).catch(() => {});
    };
  }, [clearTimer]);

  return {
    isRecording,
    audioUrl,
    duration,
    maxDuration: MAX_RECORDING_SECONDS,
    startRecording,
    stopRecording,
    setAudioUrl
  };
}
