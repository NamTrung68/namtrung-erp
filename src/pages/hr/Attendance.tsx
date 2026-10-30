import React, { useEffect, useRef, useState } from 'react';
import { Layout } from '../../components/Layout';
import { Badge, Button, Card, cx, Empty, Field, Input, Loading, Modal, NumInput, Select, Table, Td, Tabs, Textarea, toast, useAction, useLoad } from '../../components/ui';
import { db, storage } from '../../lib/sb';
import { useApp } from '../../state';
import { compressImage } from '../../lib/image';
import { fmtDate, fmtTime, monthStart, monthEnd, today } from '../../lib/format';

const REQ: [string, string][] = [['xac_nhan_cong', 'Đơn xác nhận công (quên chấm)'], ['cong_tac', 'Đơn đi công tác / gặp khách'], ['xin_muon_som', 'Xin đi muộn / về sớm']];
const RS: Record<string, [string, string]> = { cho_duyet: ['Chờ duyệt', 'amber'], da_duyet: ['Đã duyệt', 'green'], tu_choi: ['Từ chối', 'red'], huy: ['Đã hủy', 'gray'] };

export default function Attendance() {
  const a = useApp(); const [tab, setTab] = useState('me');
  return (
    <Layout title="Chấm công">
      <Tabs value={tab} onChange={setTab} tabs={[['me', 'Chấm công của tôi'], ['req', 'Đơn công'], ...((a.isLead || a.canHR) ? [['team', 'Bảng chấm công nhân sự']] as [string, string][] : [])]} />
      <div className="mt-4">{tab === 'me' ? <MyAttendance /> : tab === 'req' ? <Requests /> : <TeamAttendance />}</div>
    </Layout>
  );
}

function MyAttendance() {
  const a = useApp(); const cfg = a.settings.attendance || {};
  const [month, setMonth] = useState(today().slice(0, 7));
  const { data: ip } = useLoad(() => db.rpc('my_ip'), []);
  const { data: ev, reload } = useLoad(() => db.from('attendance_events').select('id,kind,at,work_date,ip_ok,status,selfie_path,purged_at').eq('profile_id', a.me.id).gte('work_date', month + '-01').lte('work_date', monthEnd(month + '-01')).order('at'), [month]);
  const [cam, setCam] = useState<'in' | 'out' | null>(null); const [img, setImg] = useState<string | null>(null);
  const blocked = !!ip && !ip.ok && (cfg.outside_ip || 'flag') === 'block' && (cfg.ip_whitelist || []).length > 0;
  if (a.me.work_schedule !== 'office') return <Card>Lịch làm việc của bạn ({a.me.work_schedule === 'warehouse' ? 'Kho' : 'không chấm công'}) không cần chấm công bằng ứng dụng.</Card>;
  const days = new Map<string, any[]>(); ((ev as any[]) || []).forEach(e => days.set(e.work_date, [...(days.get(e.work_date) || []), e]));
  const todayEv = days.get(today()) || [];
  const start = cfg.start || '08:00';
  const lateOf = (d: string, list: any[]) => {
    const first = list.find(e => e.kind === 'in'); if (!first) return 0;
    const t = fmtTime(first.at); const [h, m] = t.split(':').map(Number); const [sh, sm] = start.split(':').map(Number);
    return Math.max(0, h * 60 + m - (sh * 60 + sm));
  };
  const flexFrom = cfg.flex_start || '';
  const totalLate = Array.from(days.entries()).filter(([d]) => !flexFrom || d >= flexFrom).reduce((s, [d, l]) => s + lateOf(d, l), 0);
  return (
    <div className="grid gap-4 lg:grid-cols-[380px_minmax(0,1fr)] [&>*]:min-w-0">
      <div className="min-w-0 space-y-4">
        {!a.me.selfie_consent && cfg.require_selfie !== false ? <Consent /> :
          <Card title={`Hôm nay ${fmtDate(today())}`}>
            <div className="mb-3 text-sm">Mạng hiện tại: <b>{ip?.ip || '…'}</b> {ip && (ip.ok ? <Badge color="green">Mạng công ty</Badge> : <Badge color={(cfg.outside_ip || 'flag') === 'block' ? 'red' : 'amber'}>{(cfg.outside_ip || 'flag') === 'block' ? 'Ngoài mạng công ty — không chấm được' : 'Ngoài mạng công ty — sẽ cần quản lý xác nhận'}</Badge>)}</div>
            <div className="mb-3 flex gap-2 text-sm"><span>Vào: <b>{fmtTime(todayEv.find(e => e.kind === 'in')?.at) || '—'}</b></span><span>· Ra: <b>{fmtTime([...todayEv].reverse().find(e => e.kind === 'out')?.at) || '—'}</b></span></div>
            {blocked && <div className="mb-3 rounded-xl border border-red-200 bg-red-50 p-3 text-sm text-red-800">⛔ Bạn đang ở ngoài mạng công ty — hãy kết nối wifi văn phòng để chấm công. Đi công tác / gặp khách: tạo đơn ở mục <a className="font-semibold underline" href="#/hr/leave">Xin nghỉ</a>.</div>}
            <div className="grid grid-cols-2 gap-2">
              <Button variant="primary" className="h-14 text-base" disabled={blocked} onClick={() => setCam('in')}>Chấm vào</Button>
              <Button variant="dark" className="h-14 text-base" disabled={blocked} onClick={() => setCam('out')}>Chấm ra</Button>
            </div>
            <p className="mt-3 text-xs text-ink-500">Giờ làm {cfg.start}–{cfg.end}, thứ Bảy đến {cfg.saturday_end}. Quỹ linh hoạt {cfg.flex_minutes} phút/tháng cho đi muộn + về sớm (từ {fmtDate(cfg.flex_start)}). Giờ chấm lấy theo máy chủ.</p>
          </Card>}
        <Card title="Tháng này"><div className="text-sm">Số ngày có chấm công: <b>{days.size}</b><br />Đi muộn (ước tính theo giờ vào{flexFrom && today() < flexFrom ? `, tính từ ${fmtDate(flexFrom)}` : ''}): <b>{totalLate}</b> / {cfg.flex_minutes ?? 100} phút
          <div className="mt-2 h-2 rounded-full bg-ink-100"><div className={totalLate > (cfg.flex_minutes ?? 100) ? 'h-2 rounded-full bg-red-500' : 'h-2 rounded-full bg-emerald-500'} style={{ width: `${Math.min(100, totalLate / (cfg.flex_minutes || 100) * 100)}%` }} /></div></div></Card>
      </div>
      <Card className="min-w-0" title="Lịch sử chấm công" actions={<Input type="month" className="w-36" value={month} onChange={e => setMonth(e.target.value)} />} bodyClass="p-0">
        {!days.size ? <Empty>Chưa có dữ liệu</Empty> : <ul className="divide-y divide-ink-100">{Array.from(days.entries()).reverse().map(([d, l]) => {
          const late = !flexFrom || d >= flexFrom ? lateOf(d, l) : 0; const ein = l.find(e => e.kind === 'in'); const eout = [...l].reverse().find(e => e.kind === 'out');
          return <li key={d} className="grid grid-cols-[52px_1fr_1fr] items-center gap-2 px-3 py-2.5 sm:grid-cols-[90px_1fr_1fr_auto] sm:px-4">
            <div><div className="font-semibold leading-tight">{fmtDate(d).slice(0, 5)}</div><div className="text-[11px] text-ink-400">{['CN', 'T2', 'T3', 'T4', 'T5', 'T6', 'T7'][new Date(d + 'T00:00:00Z').getUTCDay()]}</div></div>
            <div className="flex min-w-0 items-center gap-1.5">{ein ? <SelfieThumb e={ein} onOpen={setImg} /> : <span className="h-10 w-10" />}<div className="leading-tight"><div className="text-[10px] uppercase text-ink-400">Vào</div><b className="tabular-nums">{fmtTime(ein?.at) || '—'}</b></div></div>
            <div className="flex min-w-0 items-center gap-1.5">{eout ? <SelfieThumb e={eout} onOpen={setImg} /> : <span className="h-10 w-10" />}<div className="leading-tight"><div className="text-[10px] uppercase text-ink-400">Ra</div><b className="tabular-nums">{fmtTime(eout?.at) || '—'}</b></div></div>
            {(late > 0 || l.some(e => e.status !== 'valid')) && <div className="col-span-3 flex flex-wrap items-center gap-1.5 text-xs sm:col-span-1 sm:justify-end">{late > 0 && <span className="font-semibold text-amber-700">muộn {late}′</span>}
              {l.some(e => e.status === 'flagged') && <Badge color="amber">Ngoài IP</Badge>}{l.some(e => e.status === 'rejected') && <Badge color="red">Bị từ chối</Badge>}</div>}
          </li>; })}</ul>}
      </Card>
      {img && <div className="fixed inset-0 z-50 grid place-items-center bg-black/80 p-4" onClick={() => setImg(null)}><img src={img} className="max-h-[88vh] max-w-full rounded-2xl shadow-2xl" alt="Ảnh chấm công" /></div>}
      {cam && <Camera kind={cam} onClose={() => setCam(null)} onDone={() => { setCam(null); reload(); a.refreshMe(); }} />}
    </div>
  );
}

function Consent() {
  const a = useApp(); const { busy, run } = useAction();
  return (
    <Card title="Đồng ý lưu ảnh chấm công">
      <div className="space-y-2 text-sm text-ink-700">
        <p>Công ty dùng ảnh selfie chụp lúc chấm công để xác nhận bạn có mặt. Ảnh được:</p>
        <ul className="list-disc pl-5"><li>nén còn khoảng 100–200 KB, lưu riêng tư;</li><li>chỉ bạn, quản lý trực tiếp và HCNS xem được;</li>
          <li>tự xóa sau {a.settings.attendance?.selfie_retention_days ?? 60} ngày (trừ ảnh đang dùng để giải quyết khiếu nại);</li><li>không dùng nhận diện khuôn mặt tự động.</li></ul>
      </div>
      <Button className="mt-3" variant="primary" loading={busy} onClick={() => run(async () => { await db.rpc('selfie_consent'); await a.refreshMe(); }, 'Đã ghi nhận đồng ý')}>Tôi đồng ý</Button>
    </Card>
  );
}

// Bộ lọc làm đẹp: b sáng · c tương phản · s bão hòa · w ấm · sm mịn da (0–1). css dùng cho xem trước.
const FILTERS: { k: string; l: string; b: number; c: number; s: number; w: number; sm: number; css: string }[] = [
  { k: 'none', l: 'Tự nhiên', b: 1, c: 1, s: 1, w: 0, sm: 0, css: 'none' },
  { k: 'glow', l: 'Rạng rỡ', b: 1.17, c: 0.93, s: 1.1, w: 7, sm: 0.4, css: 'brightness(1.17) contrast(0.93) saturate(1.1) sepia(0.05)' },
  { k: 'bright', l: 'Sáng da', b: 1.12, c: 0.95, s: 1.04, w: 4, sm: 0.25, css: 'brightness(1.12) contrast(0.95) saturate(1.04)' },
  { k: 'soft', l: 'Mịn da', b: 1.1, c: 0.92, s: 1.03, w: 6, sm: 0.5, css: 'brightness(1.1) contrast(0.92) saturate(1.03)' },
  { k: 'rosy', l: 'Hồng hào', b: 1.08, c: 0.97, s: 1.18, w: 10, sm: 0.3, css: 'brightness(1.08) contrast(0.97) saturate(1.18) sepia(0.06)' },
  { k: 'korea', l: 'Hàn Quốc', b: 1.16, c: 0.88, s: 0.9, w: 2, sm: 0.45, css: 'brightness(1.16) contrast(0.88) saturate(0.9)' },
  { k: 'warm', l: 'Nắng ấm', b: 1.05, c: 1.02, s: 1.12, w: 18, sm: 0.2, css: 'brightness(1.05) contrast(1.02) saturate(1.12) sepia(0.15)' },
];
// ---- Trang điểm (son môi + má hồng) bằng nhận diện khuôn mặt MediaPipe, tải khi mở camera, lỗi mạng thì tự bỏ qua ----
const MP = 'https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@0.10.14';
const FACE_MODEL = 'https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task';
let facePromise: Promise<any> | null = null;
function loadFace(): Promise<any> {
  if (!facePromise) facePromise = (async () => {
    const imp = new Function('u', 'return import(u)') as (u: string) => Promise<any>;
    const v = await imp(`${MP}/vision_bundle.mjs`); const fs = await v.FilesetResolver.forVisionTasks(`${MP}/wasm`);
    const opts = (delegate: string) => ({ baseOptions: { modelAssetPath: FACE_MODEL, delegate }, runningMode: 'VIDEO', numFaces: 1 });
    try { return await v.FaceLandmarker.createFromOptions(fs, opts('GPU')); } catch { return await v.FaceLandmarker.createFromOptions(fs, opts('CPU')); }
  })().catch(e => { facePromise = null; throw e; });
  return facePromise;
}
const LIP_OUT = [61, 185, 40, 39, 37, 0, 267, 269, 270, 409, 291, 375, 321, 405, 314, 17, 84, 181, 91, 146];
const LIP_IN = [78, 191, 80, 81, 82, 13, 312, 311, 310, 415, 308, 324, 318, 402, 317, 14, 87, 178, 88, 95];
const LIPS: { k: string; l: string; c: string }[] = [
  { k: 'none', l: 'Không son', c: '' }, { k: 'peach', l: 'Hồng đào', c: '226,92,120' }, { k: 'coral', l: 'Đỏ cam', c: '220,70,58' },
  { k: 'nude', l: 'Hồng nude', c: '200,112,120' }, { k: 'red', l: 'Đỏ thuần', c: '196,30,58' }, { k: 'berry', l: 'Đỏ mận', c: '150,34,64' },
];
type Pt = { x: number; y: number };
// Vẽ son + má hồng lên ctx (toạ độ ảnh gốc chưa lật). blend=true: dùng phép trộn của canvas (ảnh chụp); false: lớp phủ đặt mix-blend-mode bằng CSS (xem trước)
function drawMakeup(ctx: CanvasRenderingContext2D, lm: Pt[], w: number, h: number, lip: string, blush: boolean, blend: boolean) {
  if (!lm?.length) return;
  const P = (i: number) => [lm[i].x * w, lm[i].y * h] as const;
  const faceW = Math.hypot((lm[454].x - lm[234].x) * w, (lm[454].y - lm[234].y) * h);
  ctx.save();
  if (blush) for (const i of [50, 280]) {
    const [x, y] = P(i); const r = faceW * 0.16; const g = ctx.createRadialGradient(x, y, 0, x, y, r);
    g.addColorStop(0, 'rgba(255,105,130,0.30)'); g.addColorStop(1, 'rgba(255,105,130,0)');
    ctx.globalCompositeOperation = blend ? 'multiply' : 'source-over'; ctx.fillStyle = g; ctx.beginPath(); ctx.arc(x, y, r, 0, Math.PI * 2); ctx.fill();
  }
  const col = LIPS.find(x => x.k === lip)?.c;
  if (col) {
    const path = new Path2D(); LIP_OUT.forEach((i, j) => { const [x, y] = P(i); j ? path.lineTo(x, y) : path.moveTo(x, y); }); path.closePath();
    [...LIP_IN].reverse().forEach((i, j) => { const [x, y] = P(i); j ? path.lineTo(x, y) : path.moveTo(x, y); }); path.closePath();
    try { (ctx as any).filter = `blur(${Math.max(1, faceW / 220)}px)`; } catch { /* Safari cũ không có filter */ }
    ctx.globalCompositeOperation = blend ? 'multiply' : 'source-over'; ctx.fillStyle = `rgba(${col},0.55)`; ctx.fill(path, 'evenodd');
    if (blend) { ctx.globalCompositeOperation = 'soft-light'; ctx.fillStyle = `rgba(${col},0.45)`; ctx.fill(path, 'evenodd'); }
  }
  ctx.restore();
}

function applyBeauty(c: HTMLCanvasElement, f: typeof FILTERS[number]) {
  if (f.k === 'none') return;
  const ctx = c.getContext('2d')!; const w = c.width, h = c.height;
  if (f.sm > 0) { // mịn da: làm mờ bằng thu nhỏ – phóng to rồi phủ mờ lên ảnh gốc (chạy được trên mọi trình duyệt)
    const t = document.createElement('canvas'); t.width = Math.max(1, Math.round(w / 5)); t.height = Math.max(1, Math.round(h / 5));
    const tc = t.getContext('2d')!; tc.imageSmoothingQuality = 'high'; tc.drawImage(c, 0, 0, t.width, t.height);
    ctx.save(); ctx.globalAlpha = f.sm; ctx.imageSmoothingQuality = 'high'; ctx.drawImage(t, 0, 0, w, h); ctx.restore();
  }
  const img = ctx.getImageData(0, 0, w, h); const d = img.data;
  for (let i = 0; i < d.length; i += 4) {
    let r = d[i] * f.b, g = d[i + 1] * f.b, bl = d[i + 2] * f.b;
    r = (r - 128) * f.c + 128; g = (g - 128) * f.c + 128; bl = (bl - 128) * f.c + 128;
    const l = 0.299 * r + 0.587 * g + 0.114 * bl; r = l + (r - l) * f.s; g = l + (g - l) * f.s; bl = l + (bl - l) * f.s;
    d[i] = r + f.w; d[i + 1] = g + f.w * 0.35; d[i + 2] = bl - f.w * 0.5;
  }
  ctx.putImageData(img, 0, 0);
}

function Camera({ kind, onClose, onDone }: { kind: 'in' | 'out'; onClose: () => void; onDone: () => void }) {
  const a = useApp(); const video = useRef<HTMLVideoElement>(null); const soft = useRef<HTMLVideoElement>(null);
  const [fk, setFk] = useState(() => { try { return localStorage.getItem('nt_cam_filter') || 'glow'; } catch { return 'glow'; } });
  const flt = FILTERS.find(x => x.k === fk) || FILTERS[0];
  useEffect(() => { try { localStorage.setItem('nt_cam_filter', fk); } catch { /* */ } }, [fk]);
  const ls = (k: string, d: string) => { try { return localStorage.getItem(k) ?? d; } catch { return d; } };
  const [lip, setLip] = useState(() => ls('nt_cam_lip', 'peach')); const [blush, setBlush] = useState(() => ls('nt_cam_blush', '1') === '1');
  useEffect(() => { try { localStorage.setItem('nt_cam_lip', lip); localStorage.setItem('nt_cam_blush', blush ? '1' : '0'); } catch { /* */ } }, [lip, blush]);
  const overlay = useRef<HTMLCanvasElement>(null); const lmRef = useRef<Pt[] | null>(null); const [mk, setMk] = useState<'off' | 'loading' | 'ready' | 'fail'>('off');
  const wantMk = lip !== 'none' || blush;
  useEffect(() => {
    if (!wantMk || mk === 'ready' || mk === 'loading') return;
    setMk('loading'); let live = true;
    loadFace().then(() => live && setMk('ready')).catch(() => live && setMk('fail'));
    return () => { live = false; };
  }, [wantMk]);
  useEffect(() => {
    if (mk !== 'ready') return; let raf = 0; let last = 0; let stop = false;
    const tick = async (t: number) => {
      if (stop) return; raf = requestAnimationFrame(tick);
      const v = video.current, cv = overlay.current; if (!v || !cv || v.readyState < 2 || t - last < 66) return; last = t;
      try {
        const fl = await loadFace(); const r = fl.detectForVideo(v, performance.now()); lmRef.current = r?.faceLandmarks?.[0] || null;
        if (cv.width !== v.videoWidth) { cv.width = v.videoWidth; cv.height = v.videoHeight; }
        const ctx = cv.getContext('2d')!; ctx.clearRect(0, 0, cv.width, cv.height);
        if (lmRef.current) drawMakeup(ctx, lmRef.current, cv.width, cv.height, lip, blush, false);
      } catch { /* bỏ qua khung hình lỗi */ }
    };
    raf = requestAnimationFrame(tick);
    return () => { stop = true; cancelAnimationFrame(raf); };
  }, [mk, lip, blush]); const [shot, setShot] = useState<Blob | null>(null); const [url, setUrl] = useState(''); const [err, setErr] = useState('');
  const [note, setNote] = useState(''); const { busy, run } = useAction(); const stream = useRef<MediaStream | null>(null);
  useEffect(() => {
    navigator.mediaDevices?.getUserMedia({ video: { facingMode: 'user', width: { ideal: 960 } }, audio: false })
      .then(s => { stream.current = s; for (const v of [video.current, soft.current]) if (v) { v.srcObject = s; v.play().catch(() => {}); } })
      .catch(() => setErr('Không mở được camera. Cho phép quyền camera cho trang này rồi thử lại, hoặc chọn ảnh từ máy.'));
    return () => stream.current?.getTracks().forEach(t => t.stop());
  }, []);
  const capture = async () => {
    const v = video.current!; const c = document.createElement('canvas'); c.width = v.videoWidth; c.height = v.videoHeight;
    const ctx = c.getContext('2d', { willReadFrequently: true } as any)!; ctx.translate(c.width, 0); ctx.scale(-1, 1); ctx.drawImage(v, 0, 0);
    if (mk === 'ready' && lmRef.current) drawMakeup(ctx, lmRef.current, c.width, c.height, lip, blush, true);
    ctx.setTransform(1, 0, 0, 1, 0, 0); applyBeauty(c, flt); ctx.fillStyle = 'rgba(0,0,0,.5)'; ctx.fillRect(0, c.height - 34, c.width, 34); ctx.fillStyle = '#fff'; ctx.font = '18px sans-serif';
    ctx.fillText(`${a.me.full_name} · ${new Date().toLocaleString('vi-VN', { timeZone: 'Asia/Ho_Chi_Minh' })}`, 10, c.height - 11);
    const b = await compressImage(c); setShot(b); setUrl(URL.createObjectURL(b));
  };
  const fromFile = async (f: File) => { const b = await compressImage(f); setShot(b); setUrl(URL.createObjectURL(b)); };
  const submit = () => run(async () => {
    if (!shot) throw new Error('Chưa chụp ảnh');
    const path = `${a.me.id}/${today().slice(0, 7)}/${Date.now()}-${kind}.jpg`;
    await storage.upload('selfies', path, shot);
    const r = await db.rpc('attendance_check', { p_kind: kind, p_selfie_path: path, p_note: note || null });
    toast.ok(`Đã chấm ${kind === 'in' ? 'vào' : 'ra'} lúc ${r.at}${r.status === 'flagged' ? ' (ngoài mạng công ty — chờ quản lý xác nhận)' : ''}`);
    onDone();
  });
  return (
    <Modal open onClose={onClose} title={kind === 'in' ? 'Chấm công vào' : 'Chấm công ra'} size="sm"
      footer={<>{shot && <Button onClick={() => { setShot(null); setUrl(''); }}>Chụp lại</Button>}{shot ? <Button variant="primary" loading={busy} onClick={submit}>Xác nhận chấm công</Button> : !err && <Button variant="primary" onClick={capture}>Chụp ảnh</Button>}</>}>
      {err && <div className="mb-3 rounded-lg bg-amber-50 p-3 text-sm text-amber-800">{err}<input className="mt-2 block text-sm" type="file" accept="image/*" capture="user" onChange={e => e.target.files?.[0] && fromFile(e.target.files[0])} /></div>}
      <div className="relative overflow-hidden rounded-2xl bg-ink-900">
        {url ? <img src={url} className="w-full" alt="selfie" /> : <>
          <video ref={video} playsInline muted className="w-full -scale-x-100" style={{ filter: flt.css }} />
          <video ref={soft} playsInline muted aria-hidden className="pointer-events-none absolute inset-0 h-full w-full -scale-x-100 object-cover" style={{ filter: `${flt.css === 'none' ? '' : flt.css} blur(6px)`, opacity: flt.sm }} />
          <canvas ref={overlay} aria-hidden className="pointer-events-none absolute inset-0 h-full w-full -scale-x-100" style={{ mixBlendMode: 'multiply', display: mk === 'ready' ? 'block' : 'none' }} />
          {mk === 'loading' && <div className="absolute left-2 top-2 rounded-full bg-black/50 px-2.5 py-1 text-[11px] text-white">💄 Đang tải trang điểm…</div>}
        </>}
      </div>
      {!url && !err && <div className="-mx-1 mt-2 flex gap-1.5 overflow-x-auto px-1 pb-1 [scrollbar-width:none]">{FILTERS.map(x =>
        <button key={x.k} onClick={() => setFk(x.k)} className={cx('shrink-0 rounded-full border px-3 py-1.5 text-xs font-semibold transition', fk === x.k ? 'border-brand-600 bg-brand-600 text-white shadow-sm' : 'border-ink-200 bg-white text-ink-700')}>✨ {x.l}</button>)}</div>}
      {!url && !err && <div className="-mx-1 mt-1 flex items-center gap-1.5 overflow-x-auto px-1 pb-1 [scrollbar-width:none]">
        {LIPS.map(x => <button key={x.k} onClick={() => setLip(x.k)} title={x.l} className={cx('flex shrink-0 items-center gap-1.5 rounded-full border px-2.5 py-1.5 text-xs font-semibold transition', lip === x.k ? 'border-rose-500 bg-rose-50 text-rose-700 ring-2 ring-rose-200' : 'border-ink-200 bg-white text-ink-700')}>
          {x.c ? <span className="h-3.5 w-3.5 rounded-full border border-white shadow" style={{ background: `rgb(${x.c})` }} /> : '🚫'}{x.l}</button>)}
        <button onClick={() => setBlush(b => !b)} className={cx('shrink-0 rounded-full border px-2.5 py-1.5 text-xs font-semibold', blush ? 'border-rose-500 bg-rose-50 text-rose-700' : 'border-ink-200 bg-white text-ink-700')}>🌸 Má hồng {blush ? 'bật' : 'tắt'}</button></div>}
      {!url && !err && mk === 'fail' && wantMk && <div className="mt-1 text-[11px] text-ink-400">Chưa tải được son/má hồng (mạng yếu) — bộ lọc sáng da vẫn dùng bình thường.</div>}
      {shot && <div className="mt-2 text-xs text-ink-500">Ảnh đã nén: {Math.round(shot.size / 1024)} KB</div>}
      <Field label="Ghi chú (nếu có)" className="mt-3"><Input value={note} onChange={e => setNote(e.target.value)} /></Field>
    </Modal>
  );
}

function Requests() {
  const a = useApp(); const [open, setOpen] = useState(false);
  const { data, loading, reload } = useLoad(() => db.from('attendance_requests').select('*').eq('profile_id', a.me.id).order('created_at', { asc: false }).limit(100), []);
  const { run } = useAction();
  return (
    <Card title="Đơn công của tôi" actions={<Button variant="dark" onClick={() => setOpen(true)}>Tạo đơn</Button>} bodyClass="p-0">
      {loading ? <Loading /> : !(data as any[])?.length ? <Empty /> : <Table head={['Loại', 'Ngày', 'Lý do', 'Trạng thái', '']}>{(data as any[]).map(r => (
        <tr key={r.id}><Td>{REQ.find(x => x[0] === r.kind)?.[1]}</Td><Td>{fmtDate(r.work_date)}{r.part !== 'full' && ` (${r.part === 'am' ? 'sáng' : 'chiều'})`}{r.minutes && ` · ${r.minutes} phút`}</Td>
          <Td>{r.reason}{r.decision_note && <div className="text-xs text-ink-400">QL: {r.decision_note}</div>}</Td><Td><Badge color={RS[r.status][1]}>{RS[r.status][0]}</Badge></Td>
          <Td>{r.status === 'cho_duyet' && <Button size="sm" variant="ghost" onClick={() => run(async () => { await db.rpc('cancel_request', { p_table: 'attendance', p_id: r.id }); reload(); }, 'Đã hủy')}>Hủy</Button>}</Td></tr>))}</Table>}
      <NewReq open={open} onClose={() => setOpen(false)} onDone={() => { setOpen(false); reload(); }} />
    </Card>
  );
}
function NewReq({ open, onClose, onDone }: { open: boolean; onClose: () => void; onDone: () => void }) {
  const a = useApp(); const [f, setF] = useState({ kind: 'xac_nhan_cong', work_date: today(), part: 'full', minutes: null as number | null, reason: '' }); const { busy, run } = useAction();
  return (
    <Modal open={open} onClose={onClose} title="Tạo đơn công" size="sm" footer={<Button variant="primary" loading={busy} onClick={() => run(async () => {
      await db.from('attendance_requests').insert({ ...f, profile_id: a.me.id, minutes: f.kind === 'xin_muon_som' ? f.minutes : null }); onDone();
    }, 'Đã gửi đơn — chờ quản lý duyệt')}>Gửi đơn</Button>}>
      <div className="space-y-3">
        <p className="text-xs text-ink-500">Công tác, làm từ xa, đi muộn/về sớm: tạo ở mục <a className="text-brand-700 underline" href="#/hr/leave">Xin nghỉ</a>.</p>
        <Field label="Loại đơn"><Select options={REQ.slice(0, 1)} value={f.kind} onChange={v => setF({ ...f, kind: v })} /></Field>
        <div className="grid grid-cols-2 gap-3"><Field label="Ngày"><Input type="date" value={f.work_date} onChange={e => setF({ ...f, work_date: e.target.value })} /></Field>
          {f.kind === 'xin_muon_som' ? <Field label="Số phút"><NumInput value={f.minutes} onChange={v => setF({ ...f, minutes: v })} /></Field>
            : <Field label="Buổi"><Select options={[['full', 'Cả ngày'], ['am', 'Sáng'], ['pm', 'Chiều']]} value={f.part} onChange={v => setF({ ...f, part: v })} /></Field>}</div>
        <Field label="Lý do / địa điểm" required><Textarea value={f.reason} onChange={e => setF({ ...f, reason: e.target.value })} /></Field>
        <p className="text-xs text-ink-500">{f.kind === 'xac_nhan_cong' ? `Tối đa ${a.settings.attendance?.forgot_limit ?? 3} lần/tháng, gửi trong 24 giờ.` : f.kind === 'xin_muon_som' ? 'Gửi tối thiểu 30 phút trước giờ làm. Thời gian vẫn tính vào quỹ 100 phút.' : 'Sale gặp khách: ghi rõ tên khách, địa điểm.'}</p>
      </div>
    </Modal>
  );
}

function TeamAttendance() {
  const a = useApp(); const [d, setD] = useState(today()); const [img, setImg] = useState<string | null>(null); const { run } = useAction();
  const { data, loading, reload } = useLoad(() => db.from('attendance_events').select('*').eq('work_date', d).order('at'), [d]);
  const by = new Map<string, any[]>(); ((data as any[]) || []).forEach(e => by.set(e.profile_id, [...(by.get(e.profile_id) || []), e]));
  const staff = a.people.filter(p => p.status === 'active');
  const view = (e: any) => run(async () => { if (!e.selfie_path || e.purged_at) throw new Error('Ảnh đã xóa theo thời hạn lưu'); setImg(await storage.signedUrl('selfies', e.selfie_path, 120)); });
  const setStatus = (e: any, status: string) => run(async () => { await db.from('attendance_events').update({ status, reviewed_by: a.me.id }).eq('id', e.id); reload(); }, 'Đã cập nhật');
  return (
    <Card title="Bảng chấm công theo ngày" actions={<Input type="date" className="w-44" value={d} onChange={e => setD(e.target.value)} />} bodyClass="p-0">
      {loading ? <Loading /> : <Table head={['Nhân sự', 'Vào', 'Ra', 'Lượt chấm', '']}>{staff.filter(p => by.has(p.id) || a.isAdmin || a.canHR || p.manager_id === a.me.id).map(p => {
        const l = by.get(p.id) || [];
        return <tr key={p.id}><Td className="whitespace-nowrap">{p.full_name}</Td><Td>{fmtTime(l.find(e => e.kind === 'in')?.at) || <span className="text-ink-300">—</span>}</Td><Td>{fmtTime([...l].reverse().find(e => e.kind === 'out')?.at)}</Td>
          <Td><div className="flex flex-wrap gap-1.5">{l.map(e => <span key={e.id} className="inline-flex items-center gap-1.5 rounded-xl border border-ink-200 p-1 pr-2 text-xs">
            <SelfieThumb e={e} onOpen={u => setImg(u)} />
            <button className="font-semibold text-brand-700" onClick={() => view(e)}>{e.kind === 'in' ? 'Vào' : 'Ra'} {fmtTime(e.at)}</button>
            {e.status === 'flagged' && <><Badge color="amber">IP {e.ip}</Badge><button className="text-emerald-700" onClick={() => setStatus(e, 'valid')}>✓</button><button className="text-red-600" onClick={() => setStatus(e, 'rejected')}>✕</button></>}
            {e.status === 'rejected' && <Badge color="red">Từ chối</Badge>}</span>)}</div></Td><Td /></tr>;
      })}</Table>}
      {img && <div className="fixed inset-0 z-50 grid place-items-center bg-black/80 p-4" onClick={() => setImg(null)}>
        <img src={img} className="max-h-[88vh] max-w-full rounded-2xl shadow-2xl" alt="Ảnh chấm công" />
        <button className="absolute right-4 top-4 rounded-full bg-white/90 px-3 py-1 text-sm font-semibold" onClick={() => setImg(null)}>Đóng ✕</button></div>}
    </Card>
  );
}

// Ảnh selfie thu nhỏ, bấm để xem to
const thumbCache = new Map<string, Promise<string>>();
function SelfieThumb({ e, onOpen }: { e: any; onOpen: (url: string) => void }) {
  const [url, setUrl] = useState<string | null>(null); const ref = useRef<HTMLButtonElement>(null);
  useEffect(() => {
    if (!e.selfie_path || e.purged_at || !ref.current) return;
    const io = new IntersectionObserver(([x]) => { if (!x.isIntersecting) return; io.disconnect();
      if (!thumbCache.has(e.selfie_path)) thumbCache.set(e.selfie_path, storage.signedUrl('selfies', e.selfie_path, 3600));
      thumbCache.get(e.selfie_path)!.then(setUrl, () => thumbCache.delete(e.selfie_path)); });
    io.observe(ref.current); return () => io.disconnect();
  }, [e.selfie_path]);
  if (!e.selfie_path || e.purged_at) return <span className="grid h-10 w-10 place-items-center rounded-lg bg-ink-100 text-[9px] text-ink-400" title="Ảnh đã xóa theo thời hạn lưu">—</span>;
  return <button ref={ref} type="button" onClick={() => url && onOpen(url)} className="h-10 w-10 shrink-0 overflow-hidden rounded-lg bg-ink-100 ring-1 ring-ink-200 transition hover:ring-2 hover:ring-brand-500" title="Bấm để xem ảnh lớn">
    {url ? <img src={url} alt="" className="h-full w-full object-cover" loading="lazy" /> : <span className="block h-full w-full animate-pulse bg-ink-200" />}</button>;
}
