// Bản 28 — Thông báo đẩy (web push): điện thoại / máy tính nhận thông báo ngay cả khi app chưa mở.
//  · Khóa VAPID do hàm máy chủ "push" tự tạo lần đầu và giữ trong CSDL (không ai phải nhập tay)
//  · Mỗi thông báo mới trong ERP → CSDL gọi hàm "push" → gửi tới mọi thiết bị đã bật của người nhận
//  · iPhone: phải mở từ biểu tượng trên màn hình chính (đã "Thêm vào MH chính"), iOS 16.4 trở lên
import { db } from './sb';

const FN = () => (window.NT_CONFIG?.supabaseUrl || '') + '/functions/v1/push';
const b64ToBytes = (s: string) => { const p = '='.repeat((4 - (s.length % 4)) % 4); const raw = atob((s + p).replace(/-/g, '+').replace(/_/g, '/')); return Uint8Array.from(raw, c => c.charCodeAt(0)); };
const bytesToB64 = (b: ArrayBuffer | null) => (b ? btoa(String.fromCharCode(...new Uint8Array(b))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '') : '');

export const pushSupported = () => typeof window !== 'undefined' && 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window;
export const isStandalone = () => matchMedia('(display-mode: standalone)').matches || (navigator as any).standalone === true;
export const isIOS = () => /iPhone|iPad|iPod/.test(navigator.userAgent);

async function publicKey(): Promise<string> {
  let k = await db.rpc<string | null>('push_public_key').catch(() => null);
  if (!k) {
    const r = await fetch(FN(), { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ init: true }) });
    k = (await r.json().catch(() => ({})))?.public_key || null;
  }
  if (!k) throw new Error('Máy chủ thông báo chưa sẵn sàng — báo Admin');
  return k;
}

/** Đăng ký nhận thông báo đẩy cho thiết bị này (gọi sau khi đã được cấp quyền Notification). */
export async function subscribePush(): Promise<boolean> {
  if (!pushSupported() || Notification.permission !== 'granted') return false;
  const reg = await navigator.serviceWorker.ready;
  const key = await publicKey();
  let sub = await reg.pushManager.getSubscription();
  // khóa máy chủ đổi → đăng ký lại
  const cur = sub?.options?.applicationServerKey ? bytesToB64(sub.options.applicationServerKey as ArrayBuffer) : '';
  if (sub && cur && cur !== key) { await sub.unsubscribe().catch(() => {}); sub = null; }
  if (!sub) sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: b64ToBytes(key) });
  const j = sub.toJSON() as any;
  await db.rpc('push_subscribe', { p_endpoint: sub.endpoint, p_p256dh: j.keys?.p256dh, p_auth: j.keys?.auth, p_ua: navigator.userAgent });
  try { localStorage.setItem('nt_push', '1'); } catch { /* ignore */ }
  return true;
}

/** Xin quyền + đăng ký (phải gọi từ thao tác bấm của người dùng — bắt buộc trên iPhone). */
export async function enablePush(): Promise<NotificationPermission> {
  const p = await Notification.requestPermission();
  if (p === 'granted') await subscribePush();
  return p;
}

/** Mỗi lần mở app: thiết bị đã cho phép thì làm mới đăng ký (endpoint có thể đổi) — im lặng nếu lỗi. */
export function ensurePush() {
  if (!pushSupported() || Notification.permission !== 'granted') return;
  subscribePush().catch(() => { try { localStorage.removeItem('nt_push'); } catch { /* ignore */ } });
}
export const pushActive = () => { try { return localStorage.getItem('nt_push') === '1' && typeof Notification !== 'undefined' && Notification.permission === 'granted'; } catch { return false; } };
