/**
 * @license
 * SPDX-License-Identifier: Apache-2.0
 */

import { io } from "socket.io-client";
import { API_BASE_URL } from "../config";

const socketUrl = typeof window !== 'undefined' && window.location?.origin && window.location.origin !== 'null' && !window.location.origin.startsWith('file://')
  ? window.location.origin
  : API_BASE_URL;

const socket = io(socketUrl, {
  transports: ['websocket', 'polling'],
  autoConnect: true,
  reconnection: true,
  reconnectionAttempts: Infinity,
  reconnectionDelay: 1000,
});

export default socket;
