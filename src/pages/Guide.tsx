// Bản 26 — Trang hướng dẫn trong hệ thống
//  · #/hd/guide : Hướng dẫn quy trình Kế toán – Hóa đơn (Kế toán, Sale, Quản lý, Admin)
//  · #/guide    : Hướng dẫn tổng quan sử dụng hệ thống theo từng bộ phận
// Nội dung viết dạng chữ đơn giản (## không dùng; ### tiêu đề nhỏ, "- " gạch đầu dòng, "1. " bước, "> " ghi chú, "!> " cảnh báo, "| " bảng, **đậm**, `mã`)
// để tìm kiếm được và sửa nhanh ngay trong file này.
import React, { useMemo, useState } from 'react';
import { Layout } from '../components/Layout';
import { Input, cx } from '../components/ui';
import { useRoute } from '../state';

export interface GuideSec { id: string; icon: string; title: string; who: string[]; text: string }

// ---------- trình hiển thị chữ đơn giản ----------
function inline(s: string, key = 0): React.ReactNode[] {
  const out: React.ReactNode[] = []; const re = /\*\*(.+?)\*\*|`(.+?)`|\[(.+?)\]\((#[^)]+)\)/g; let last = 0; let m: RegExpExecArray | null; let i = 0;
  while ((m = re.exec(s))) {
    if (m.index > last) out.push(s.slice(last, m.index));
    if (m[1]) out.push(<b key={`${key}-${i++}`} className="font-semibold text-ink-900">{m[1]}</b>);
    else if (m[2]) out.push(<code key={`${key}-${i++}`} className="rounded bg-ink-100 px-1 py-0.5 text-[12.5px] text-ink-800">{m[2]}</code>);
    else out.push(<a key={`${key}-${i++}`} href={m[4]} className="font-semibold text-brand-700 underline decoration-brand-200 underline-offset-2">{m[3]}</a>);
    last = re.lastIndex;
  }
  if (last < s.length) out.push(s.slice(last));
  return out;
}
function Rich({ text }: { text: string }) {
  const lines = text.replace(/^\n+|\s+$/g, '').split('\n'); const blocks: React.ReactNode[] = []; let i = 0; let k = 0;
  while (i < lines.length) {
    const l = lines[i];
    if (!l.trim()) { i++; continue; }
    if (l.startsWith('### ')) { blocks.push(<h4 key={k++} className="mt-5 text-[15px] font-extrabold text-ink-900 first:mt-0">{inline(l.slice(4), k)}</h4>); i++; continue; }
    if (l.startsWith('- ')) { const it: string[] = []; while (i < lines.length && lines[i].startsWith('- ')) it.push(lines[i++].slice(2));
      blocks.push(<ul key={k++} className="mt-2 list-disc space-y-1 pl-5 marker:text-ink-300">{it.map((x, j) => <li key={j}>{inline(x, j)}</li>)}</ul>); continue; }
    if (/^\d+\. /.test(l)) { const it: string[] = []; while (i < lines.length && /^\d+\. /.test(lines[i])) it.push(lines[i++].replace(/^\d+\. /, ''));
      blocks.push(<ol key={k++} className="mt-2 space-y-1.5">{it.map((x, j) => <li key={j} className="flex gap-2.5"><span className="mt-0.5 grid h-5 w-5 shrink-0 place-items-center rounded-full bg-ink-900 text-[11px] font-bold text-white">{j + 1}</span><span className="min-w-0">{inline(x, j)}</span></li>)}</ol>); continue; }
    if (l.startsWith('> ') || l.startsWith('!> ')) { const warn = l.startsWith('!'); const it: string[] = [];
      while (i < lines.length && (lines[i].startsWith(warn ? '!> ' : '> '))) it.push(lines[i++].slice(warn ? 3 : 2));
      blocks.push(<div key={k++} className={cx('mt-3 rounded-xl border px-3.5 py-2.5', warn ? 'border-amber-200 bg-amber-50 text-amber-900' : 'border-brand-100 bg-brand-50/60 text-ink-700')}>
        {it.map((x, j) => <p key={j} className={j ? 'mt-1' : ''}>{warn && j === 0 ? '⚠️ ' : j === 0 ? '💡 ' : ''}{inline(x, j)}</p>)}</div>); continue; }
    if (l.startsWith('| ')) { const rows: string[][] = []; while (i < lines.length && lines[i].startsWith('| ')) rows.push(lines[i++].replace(/^\|\s*|\s*\|\s*$/g, '').split(/\s*\|\s*/));
      const [h, ...body] = rows;
      blocks.push(<div key={k++} className="mt-3 overflow-x-auto rounded-xl border border-ink-200"><table className="w-full min-w-[520px] text-left text-[13px]">
        <thead className="bg-ink-50 text-[11.5px] uppercase tracking-wide text-ink-500"><tr>{h.map((c, j) => <th key={j} className="px-3 py-2 font-bold">{inline(c, j)}</th>)}</tr></thead>
        <tbody className="divide-y divide-ink-100">{body.map((r, j) => <tr key={j}>{r.map((c, n) => <td key={n} className="px-3 py-2 align-top">{inline(c, n)}</td>)}</tr>)}</tbody></table></div>); continue; }
    const para: string[] = []; while (i < lines.length && lines[i].trim() && !/^(### |- |\d+\. |> |!> |\| )/.test(lines[i])) para.push(lines[i++]);
    blocks.push(<p key={k++} className="mt-2 first:mt-0">{inline(para.join(' '), k)}</p>);
  }
  return <div className="text-[14px] leading-relaxed text-ink-700">{blocks}</div>;
}

const fold = (s: string) => s.normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/đ/g, 'd').replace(/Đ/g, 'D').toLowerCase();

function GuidePage({ title, intro, secs, roles }: { title: string; intro: React.ReactNode; secs: GuideSec[]; roles: string[] }) {
  const { query } = useRoute(); const [q, setQ] = useState(''); const [role, setRole] = useState('');
  const view = useMemo(() => { const qq = fold(q.trim());
    return secs.filter(s => (!role || s.who.includes(role) || s.who.includes('Tất cả')) && (!qq || fold(s.title + ' ' + s.text).includes(qq))); }, [secs, q, role]);
  const jump = (id: string) => document.getElementById('g-' + id)?.scrollIntoView({ behavior: 'smooth', block: 'start' });
  React.useEffect(() => { if (query.s) setTimeout(() => jump(query.s), 50); }, [query.s]);
  const toc = <ul className="space-y-0.5">{view.map(s => <li key={s.id}><button type="button" onClick={() => jump(s.id)} className="flex w-full items-start gap-2 rounded-lg px-2 py-1.5 text-left text-[13px] font-semibold text-ink-600 hover:bg-white hover:text-ink-900"><span className="w-5 shrink-0 text-center">{s.icon}</span><span className="min-w-0">{s.title}</span></button></li>)}</ul>;
  return (
    <Layout title={title}>
      <div className="mx-auto grid max-w-6xl gap-5 lg:grid-cols-[250px_minmax(0,1fr)]">
        <aside className="hidden lg:block"><div className="sticky top-20 max-h-[calc(100vh-6rem)] overflow-y-auto pr-1">
          <div className="mb-2 px-2 text-[11px] font-bold uppercase tracking-wider text-ink-400">Mục lục</div>{toc}</div></aside>
        <div className="min-w-0">
          <div className="rounded-3xl border border-ink-200 bg-white p-4 shadow-soft sm:p-6">
            <div className="text-[14px] leading-relaxed text-ink-700">{intro}</div>
            <Input className="mt-4" placeholder="🔎 Tìm trong hướng dẫn (không cần dấu): biên, PDF nháp, quên chấm công…" value={q} onChange={e => setQ(e.target.value)} />
            <div className="-mx-1 mt-3 flex gap-1.5 overflow-x-auto px-1 pb-1 [scrollbar-width:none]">
              {['', ...roles].map(r => <button key={r} type="button" onClick={() => setRole(r)} className={cx('shrink-0 rounded-full border px-3 py-1.5 text-xs font-semibold transition', role === r ? 'border-ink-900 bg-ink-900 text-white' : 'border-ink-200 bg-white text-ink-600 hover:border-ink-400')}>{r || 'Tất cả bộ phận'}</button>)}
            </div>
            <details className="mt-3 rounded-xl border border-ink-200 bg-ink-50 px-3 py-2 lg:hidden"><summary className="cursor-pointer text-sm font-semibold">Mục lục ({view.length})</summary><div className="mt-1">{toc}</div></details>
          </div>
          {!view.length && <div className="mt-4 rounded-2xl border border-dashed border-ink-300 p-8 text-center text-sm text-ink-500">Không tìm thấy nội dung phù hợp. Thử từ khóa khác, hoặc hỏi ở mục <a className="font-semibold text-brand-700" href="#/tickets">Claim & hỏi đáp</a>.</div>}
          {view.map(s => (
            <section key={s.id} id={'g-' + s.id} className="mt-4 scroll-mt-20 rounded-3xl border border-ink-200 bg-white p-4 shadow-soft sm:p-6">
              <div className="mb-3 flex flex-wrap items-center gap-2">
                <span className="grid h-9 w-9 place-items-center rounded-xl bg-ink-100 text-lg">{s.icon}</span>
                <h3 className="min-w-0 flex-1 text-lg font-extrabold tracking-tight text-ink-900">{s.title}</h3>
                <div className="flex flex-wrap gap-1">{s.who.map(w => <span key={w} className="rounded-full bg-ink-100 px-2 py-0.5 text-[11px] font-semibold text-ink-600">{w}</span>)}</div>
              </div>
              <Rich text={s.text} />
            </section>))}
          <p className="mt-6 pb-6 text-center text-xs text-ink-400">Hướng dẫn cập nhật theo phiên bản hệ thống. Chỗ nào chưa rõ hoặc thấy sai thực tế → gửi ở <a className="font-semibold text-brand-700" href="#/tickets">Claim & hỏi đáp</a> để Admin bổ sung.</p>
        </div>
      </div>
    </Layout>
  );
}

// =====================================================================
// 1) QUY TRÌNH KẾ TOÁN – HÓA ĐƠN
// =====================================================================
const HD: GuideSec[] = [
  { id: 'tong-quan', icon: '🗺️', title: 'Tổng quan: 3 chu kỳ của một xe hàng', who: ['Tất cả'], text: `
Mỗi xe hàng nhập qua APT đi qua **3 chu kỳ**. Hệ thống NamtrungLog (file xe – khai báo hệ thống) là **gốc**: đơn, khách, sale, giá khách đều lấy từ đây.

| Chu kỳ | Việc chính | Ai làm | Màn hình |
| ① Đối soát nháp | Ghép **nháp APT** với **file xe**, kiểm biên Nam Trung, chốt giá với APT | Kế toán nạp file · Sale xử lý dòng của mình | [Bàn làm việc kế toán](#/hd/kt) · [Đối soát xe của tôi](#/acc/mine) |
| ② HĐ chính thức APT (đầu vào) | Nạp HĐ APT đã ký, ghép về dòng nháp, đối chiếu từng dòng | Kế toán | [Bàn làm việc kế toán](#/hd/kt) |
| ③ Xuất HĐ cho khách (đầu ra) | Sale tạo yêu cầu → kế toán export MISA → PDF nháp → khách OK → ký | Sale · Kế toán · Quản lý duyệt giá | [Hóa đơn của tôi](#/hd) · [Bàn làm việc kế toán](#/hd/kt) |

### Luồng một dòng hàng từ đầu đến cuối
1. Xe chạy → APT gửi **nháp HĐ** (Google Sheet) + Nam Trung có **file xe** (khai báo hệ thống).
2. Kế toán bấm **⇪ ① Nạp nháp APT + file xe** → hệ thống ghép, tính biên.
3. Sale vào **Đối soát xe của tôi**: dòng biên ngoài khung → copy giá đề xuất dán Google Sheet APT → bấm đã gửi; dòng "chưa có chủ" → nhận dòng.
4. APT xuất **HĐ chính thức** → kế toán bấm **⇪ ② Nạp HĐ chính thức APT** → dòng khớp sẽ vào kho "Sẵn sàng xuất" của sale.
5. Sale tạo **yêu cầu xuất HĐ** (theo đơn / gộp đơn / chọn mã) → gửi kế toán (biên > 4% thì chờ quản lý duyệt giá).
6. Kế toán **export file MISA** → lập nháp trên MISA → tải **PDF nháp** lên ERP.
7. Sale xem PDF nháp → gửi khách → khách OK thì **Chốt**, sai thì **Yêu cầu sửa**.
8. Kế toán **ký trên MISA** → tải **PDF đã ký** lên → yêu cầu sang **Đã ký**. Sale in được bản ký để làm hợp đồng.

> Mỗi yêu cầu luôn hiện dòng **"Ai: việc tiếp theo"** (VD: "Kế toán: tải PDF nháp", "Sale: gửi khách nháp v1"). Nhìn dòng này là biết đang chờ ai.
!> Module này **không** quản lý công nợ, phí dịch vụ, phí vận chuyển — chỉ hóa đơn hàng hóa đầu vào (APT) và đầu ra (khách).` },

  { id: 'thuat-ngu', icon: '📖', title: 'Thuật ngữ cần biết', who: ['Tất cả'], text: `
| Từ | Nghĩa |
| Nháp APT | Bảng nháp HĐ APT gửi trước khi xuất HĐ thật (Google Sheet của APT) |
| File xe | File khai báo của Nam Trung cho xe đó: mã khai báo, mã đơn MD, khách, sale, SL, giá khách |
| Mã khai báo | Mã từng dòng hàng khai báo hải quan — **khóa chính để ghép** nháp APT với file xe |
| MD / ID đơn | Mã đơn trên NamtrungLog, hiển thị dạng \`2411\` hoặc \`MD2411\` (hai cách ghi là một) |
| Giá APT | Đơn giá trên HĐ APT (giá nhập của Nam Trung) |
| Giá khách | Đơn giá Nam Trung xuất cho khách |
| Biên NT | \`giá khách ÷ giá APT − 1\`. Mục tiêu khoảng 3% |
| Mã hàng HĐ ký | Dạng \`HH00013-2080-2026\` (2080 = số HĐ APT) — mã kế toán dùng trên MISA |
| Pháp nhân | Thông tin xuất HĐ của khách (tên, MST hoặc CCCD, địa chỉ, email). Một khách có thể có nhiều pháp nhân |
| Dòng khóa / lệch | Dòng HĐ APT lệch nháp (SL, đơn giá, thuế suất) — bị khóa, sale chưa xuất được tới khi kế toán xử lý |
| Dòng chưa có chủ | Hàng đã lên xe nhưng không tìm thấy đơn / sale trên hệ thống |
| Tồn HĐ đầu vào | Hàng đã có HĐ APT nhưng sale chưa tạo yêu cầu xuất cho khách |` },

  { id: 'chu-ky-1', icon: '①', title: 'Chu kỳ 1 — Đối soát nháp APT ↔ file xe', who: ['Kế toán', 'Sale'], text: `
### Kế toán làm
1. Vào [Bàn làm việc kế toán](#/hd/kt) → khối **① Xe & HĐ APT** → bấm **⇪ ① Nạp nháp APT + file xe**.
2. Chọn file nháp APT và file xe (tải **file mẫu** ở cùng khối nếu cần). Hệ thống đọc **theo tiêu đề cột** — thêm cột hay đổi thứ tự cột vẫn đọc được. Tờ khai nháp không bắt buộc.
3. Xem kết quả ghép, bấm lưu. Xe mới xuất hiện trong danh sách xe.

### Hệ thống ghép thế nào
1. Khớp **đủ mã khai báo + số lượng** → ghép chuẩn.
2. Lệch mã → ghép theo **mã đơn MD + số lượng**, ghi chú "Ghép theo đơn – lệch mã".
3. Đúng mã mà lệch số lượng → **cảnh báo sai số** (1 đơn = 1 xe, thiếu SL là sai, cần kiểm).
4. **Không ghép theo tên hàng** ở chu kỳ này. Đơn vị tính (PCE / Cái) không so.

### Kiểm biên Nam Trung (theo từng mã khai báo)
Các mức lấy theo **Cấu hình → Kế toán – Hóa đơn** (mặc định: tối thiểu 2,5% · tối đa 4% · mức chặn 7%).

| Biên | Hệ thống làm gì | Sale làm gì |
| Dưới tối thiểu (kể cả **biên âm**) | **Chặn** — vào tab **Cần xử lý** của sale | Sửa giá khách nếu sai, hoặc gửi APT giá đề xuất, hoặc xin duyệt |
| Tối thiểu – tối đa | Tự chốt | Không cần làm gì |
| Tối đa – 7% | Tự chốt + cảnh báo, có giá đề xuất | Nên gửi APT giá đề xuất (tab **Đề xuất giá gửi APT**) |
| Trên 7% | **Chặn** — vào tab **Cần xử lý** | Như dòng dưới tối thiểu |

### Cách xử lý dòng bị chặn vì biên
- **Sửa giá khách (chốt luôn)**: giá khách trên dòng sai so với hệ thống (đã sửa trên NamtrungLog) → nhập giá đúng. Hệ thống tính lại biên ngay; biên mới **trong khung tối thiểu – 7%** thì dòng **chốt luôn, không cần kế toán / admin duyệt**. Ngoài khung thì không gửi được.
- **Đã gửi APT giá đề xuất**: giá đề xuất = **giá khách ÷ (1 + mục tiêu)**. Copy gửi APT, bấm xác nhận là chốt.
- **Xin duyệt ngoại lệ**: trường hợp đặc biệt, ghi lý do.

> Giá đề xuất hiện **số liền, không dấu chấm phẩy** để dán thẳng. Tab **Đề xuất giá gửi APT** có nút **📋 Copy tất cả gửi APT** và **⬇ Xuất Excel** — cột cuối file Excel chỉ có giá đề nghị, số liền.
!> Đề xuất hạ giá chỉ hợp lệ khi vẫn **≥ giá vốn tờ khai**. Dòng bị chặn chưa xử lý thì quá hạn sẽ bị nhắc.

### Sale làm — [Đối soát xe của tôi](#/acc/mine)
- Tab **Cần xử lý**: dòng bị chặn (biên ngoài khung, thiếu đơn, thiếu giá…). Biên sai do giá khách sai → **Sửa giá khách**; còn lại copy giá đề xuất gửi APT rồi bấm xác nhận.
- Tab **Dòng chưa có chủ**: hàng của khách mình mà chưa có đơn → tạo đơn trên NamtrungLog → bấm **Nhận dòng này**, nhập MD + giá khách. Kế toán kiểm rồi chốt.
- Hàng **"không khai"** (đi đường khác, không xuất HĐ qua APT): sale đóng dòng, kế toán xác nhận thêm 1 lần.

### Mở chặn HĐ
Dòng bị chặn mà cần mở (có lý do chính đáng) → người được cấp quyền vào [Duyệt mở chặn HĐ](#/acc/approve). Admin / BGĐ chọn người duyệt ở **Cấu hình → Kế toán – Hóa đơn**.` },

  { id: 'chu-ky-2', icon: '②', title: 'Chu kỳ 2 — Nạp HĐ chính thức APT (đầu vào)', who: ['Kế toán'], text: `
1. APT xuất HĐ chính thức → kế toán vào [Bàn làm việc kế toán](#/hd/kt) → **⇪ ② Nạp HĐ chính thức APT**.
2. Hệ thống ghép mỗi dòng HĐ ký về **dòng nháp của xe** theo **tên hàng** (bỏ khoảng trắng, dấu chấm cuối) **+ số lượng**. Tên trên HĐ ký và nháp giống ~99% nên khớp được; APT không giữ mã khai báo trên HĐ ký.
3. Ghép xong, dòng HĐ nhận lại: mã khai báo, đơn, khách, sale, giá khách từ dòng nháp.
4. Hệ thống **đối chiếu chi tiết từng dòng**: số lượng, đơn giá, thuế suất (không so tổng HĐ).
5. Kết quả xem trước được lưu đúng như đã xem. Nạp lại cùng HĐ: dòng đã sửa tay giữ nguyên, dòng đổi ghép thì xóa liên kết cũ rồi ghép lại.
6. **Tên hàng lưu vào bảng gốc là tên trên HĐ chính thức** (file kế toán nạp); tên nháp chỉ dùng để ghép.
7. Ô **Thiếu username khách** (đỏ): đơn chưa có username, hoặc username trùng số đơn (file xe lệch cột) → điền ngay trên dòng rồi lưu. Không điền vẫn lưu được, hàng nằm ở nhóm **⚠ Thiếu ID đơn / username khách** trong "Sẵn sàng xuất" — sale / CSKH / kế toán bấm **Điền đơn / khách**.

### File xe lệch cột (bản 32)
- ERP lấy đơn theo **MÃ KHAI BÁO** (MD2689-1 → đơn MD2689), không tin ô ID ĐƠN khi hai ô khác nhau.
- Dòng bị đảo **ID ĐƠN ↔ USERNAME** được tự đảo lại và báo vàng trên màn phân tích.
- Nạp lại file xe đã sửa → đơn + username mới tự sang bảng gốc HĐ (trừ dòng đã lập phiếu hoặc kế toán sửa tay). File mới để trống username thì giữ username đã điền.

### Xử lý dòng lỗi (khu "Dòng HĐ cần kế toán xử lý")
- **Lệch nháp → khóa**: kiểm với APT; đúng thì **chấp nhận kèm lý do**, sai thì yêu cầu APT sửa.
- **Chưa ghép được dòng nháp** (tên / SL không khớp): **ghép tay** vào đúng dòng nháp.
- Dòng sạch tự chuyển sang **"Sẵn sàng xuất"** của sale phụ trách.

> Sau chu kỳ 2, hàng đã có HĐ đầu vào mà sale chưa xuất → hiện trong **Báo cáo tồn HĐ đầu vào** ở [Duyệt giá & tồn HĐ](#/hd/ql).` },

  { id: 'chu-ky-3', icon: '③', title: 'Chu kỳ 3 — Sale tạo yêu cầu xuất HĐ cho khách', who: ['Sale', 'Quản lý'], text: `
Vào [Hóa đơn của tôi](#/hd) → tab **Sẵn sàng xuất**. Hàng gom theo **Khách → Đơn → Mã khai báo**.

### 3 cách tạo yêu cầu
| Cách | Khi nào dùng | Thao tác |
| Xuất theo đơn (~80%) | Mọi mã của 1 đơn vào 1 HĐ | Bấm **Xuất theo đơn** ở dòng đơn |
| Gộp nhiều đơn (~12%) | Khách muốn nhiều đơn vào 1 HĐ | Tick các đơn **cùng 1 khách** → **Gộp** |
| Chọn mã cụ thể (~8%) | Khách lấy hàng nhiều đợt, chỉ xuất một phần | Mở đơn, tick mã + sửa SL → **Chọn mã** |
| Xuất hàng loạt | Nhiều đơn "sạch" cùng lúc | **⚡ Xuất hàng loạt các đơn sạch** → xem màn xác nhận tổng → gửi |

> "Đơn sạch" = đủ đơn, đủ giá, đủ pháp nhân, không dòng khóa, biên trong khung. Đơn chưa sạch hiện kèm **lý do** để xử lý tay.

### Pháp nhân và giá
- Pháp nhân **mặc định theo khách** (khớp bằng username khách). Khách có nhiều pháp nhân → chọn đúng cái khách cần. Khách cá nhân dùng **CCCD**.
- Giá lấy tự động từ giá khách; sale **sửa được**, hệ thống báo % biên so với giá APT:

| Biên so với giá APT | Kết quả |
| Dưới 2% | **Cấm** — không tạo được |
| 2% – 4% | Gửi thẳng kế toán, không cần duyệt |
| Trên 4% | Vẫn tạo được, chuyển **Chờ duyệt giá** — 1 người (Kế toán / Quản lý / Admin) duyệt là đủ |

### Trạng thái yêu cầu và ai làm tiếp
| Trạng thái | Nghĩa | Việc tiếp theo |
| Sale đang soạn | Chưa gửi | Sale: gửi kế toán |
| Chờ duyệt giá | Biên > 4% | Quản lý: duyệt giá |
| Đã gửi — chờ export | Tới lượt kế toán | Kế toán: xuất file nhập MISA |
| Đã export — chờ PDF nháp | Kế toán đã xuất MISA | Kế toán: tải PDF nháp |
| Có nháp — chờ sale duyệt | Đã có PDF nháp | Sale: gửi khách → Chốt / Yêu cầu sửa |
| Sale trả sửa | Khách / sale cần sửa | Kế toán: sửa nháp, xuất lại MISA |
| Đã chốt — chờ ký | Khách đồng ý | Kế toán: ký MISA, tải PDF đã ký |
| Đã ký | Hoàn tất | Sale in / gửi khách bản ký |

!> Sau khi kế toán **đã export MISA**, sale **không hủy** được yêu cầu nữa — chỉ **Yêu cầu sửa**, sửa xong gửi lại (lên **phiên bản mới**, v2, v3…).

### Tab trong "Hóa đơn của tôi"
- **Sẵn sàng xuất**: hàng chờ tạo yêu cầu. Lọc "Tồn quá 3 ngày", "Biên cảnh báo / đang khóa".
- **Chờ tôi duyệt nháp**: có PDF nháp — việc gấp nhất của sale.
- **Bị trả / chờ duyệt giá**: cần sửa hoặc đang chờ quản lý.
- **Đang xử lý**: đang ở phía kế toán.
- **Đã ký**: xem / in PDF nháp và PDF đã ký.` },

  { id: 'ke-toan', icon: '🧾', title: 'Bàn làm việc kế toán — thứ tự xử lý trong ngày', who: ['Kế toán'], text: `
[Bàn làm việc kế toán](#/hd/kt) chia **4 khối theo thứ tự** làm trong ngày. Làm từ trên xuống, khối nào trống là xong.

1. **① Xe & HĐ APT** — nạp nháp APT + file xe (chu kỳ 1), nạp HĐ chính thức APT (chu kỳ 2), nạp **Đơn hàng · pháp nhân**. Xử lý dòng lệch / chưa ghép.
2. **② Yêu cầu mới → export MISA** — chỉ gồm yêu cầu đã gửi (biên 2–4% hoặc đã được duyệt giá). Chọn → **xuất file nhập MISA** → nhập vào MISA lập nháp. Khu đỏ phía trên là yêu cầu **Chờ duyệt giá** (kế toán duyệt được).
3. **③ PDF nháp** — tải PDF nháp MISA lên. Hệ thống khớp PDF với yêu cầu bằng **MST (hoặc CCCD) + tổng tiền (+ ngày)**.
4. **④ Chờ ký** — sale đã chốt → ký trên MISA → tải **PDF đã ký** lên → yêu cầu thành **Đã ký**, điền số HĐ.

### Đặt tên file PDF chuẩn (để tự khớp)
| Loại | Tên file |
| PDF nháp | \`NHAP_<MST hoặc CCCD>_<Tổng tiền>_<yyyymmdd>_<stt>.pdf\` |
| PDF đã ký | \`KY_<Ký hiệu>-<Số HĐ>_<MST hoặc CCCD>_<Tổng tiền>.pdf\` |

> Tên file khác chuẩn: ERP tự đọc chữ trong PDF để tìm MST và số tiền. Vẫn không khớp → chọn yêu cầu bằng tay.
!> Tải **bản nháp mới** (v2…) cho yêu cầu đã có nháp → yêu cầu quay về "Có nháp — chờ sale", **xác nhận ký bản cũ tự hủy**, sale được báo. Chỉ tải bản đã ký khi sale đã chốt.

### Checklist cuối ngày của kế toán
- Khối ② không còn yêu cầu quá 1 ngày chưa export.
- Khối ③ mọi yêu cầu đã export đều có PDF nháp.
- Khối ④ yêu cầu đã chốt được ký trong ngày.
- Không còn dòng HĐ APT lệch / chưa ghép tồn quá 2 ngày.` },

  { id: 'quan-ly', icon: '✅', title: 'Quản lý: duyệt giá, theo dõi tồn, làm thay sale vắng', who: ['Quản lý', 'Admin'], text: `
- [Duyệt giá & tồn HĐ](#/hd/ql): duyệt yêu cầu biên **> 4%**. Xem lý do sale ghi, so với giá thị trường / lịch sử khách. **1 người duyệt là đủ** (Kế toán, Quản lý hoặc Admin).
- **Tồn HĐ đầu vào chưa xuất** theo từng sale: hàng đã có HĐ APT mà sale chưa tạo yêu cầu → nhắc sale trong buổi họp ngày.
- Trưởng nhóm / Trưởng phòng / Admin xem được yêu cầu của **sale dưới quyền** (ô chọn sale ở góc trên [Hóa đơn của tôi](#/hd)).
- Sale **nghỉ hoặc vắng**: TN / TP thao tác thay bình thường (tạo yêu cầu, chốt nháp…). Mọi thao tác đều ghi nhật ký người làm.

### Chỉ số nên theo dõi hàng tuần
| Chỉ số | Mục tiêu gợi ý |
| Tồn HĐ đầu vào quá 3 ngày | 0 dòng |
| Yêu cầu chờ duyệt giá quá 1 ngày | 0 |
| Thời gian từ "Có nháp" đến "Đã chốt" | ≤ 2 ngày |
| Tỷ lệ yêu cầu bị trả sửa | < 10% |` },

  { id: 'bao-mat', icon: '🔐', title: 'Quyền xem và bảo mật file hóa đơn', who: ['Tất cả'], text: `
- PDF nháp / đã ký lưu **kín** trên Google Drive công ty (thư mục \`ERP_NAMTRUNG\`), không chia sẻ công khai. ERP chỉ mở qua **vé dùng 1 lần** (hết hạn sau vài phút).
- **Ai xem được**: sale của yêu cầu, cấp trên theo cây nhân sự, Kế toán, Admin, BGĐ. **Sale không xem chéo** HĐ của sale khác — trên ERP lẫn Drive.
- **Ai tải PDF lên**: Kế toán, Admin, BGĐ.
- Mỗi lần mở file đều **ghi nhật ký** (ai, lúc nào).
!> Không tải PDF HĐ về rồi gửi qua nhóm chat chung. Gửi khách trực tiếp từ máy / Zalo của sale phụ trách.` },

  { id: 'faq', icon: '❓', title: 'Lỗi thường gặp và cách xử lý', who: ['Tất cả'], text: `
| Hiện tượng | Nguyên nhân thường gặp | Cách xử lý |
| Không thấy hàng ở "Sẵn sàng xuất" | Kế toán chưa nạp HĐ chính thức APT, hoặc dòng đang khóa | Xem tab "Biên cảnh báo / đang khóa"; hỏi kế toán xe đó đã nạp HĐ APT chưa |
| Không tạo được yêu cầu, báo "dưới 2%" | Giá xuất thấp hơn giá APT + 2% | Sửa giá; giá khách thực sự thấp → báo quản lý |
| Yêu cầu nằm mãi ở "Chờ duyệt giá" | Biên > 4%, chưa ai duyệt | Nhắn Quản lý / Kế toán duyệt ở [Duyệt giá & tồn HĐ](#/hd/ql) |
| "Khác khách — không gộp được 1 HĐ" | Tick đơn của 2 khách khác nhau | Chỉ gộp đơn cùng 1 khách |
| Muốn hủy yêu cầu nhưng không có nút | Kế toán đã export MISA | Dùng **Yêu cầu sửa**, ghi rõ cần đổi gì |
| PDF nháp không tự khớp | Tên file sai chuẩn, MST / số tiền khác yêu cầu | Đổi tên file theo chuẩn hoặc chọn yêu cầu bằng tay |
| Dòng "chưa có chủ" của khách mình | Chưa tạo đơn trên NamtrungLog | Tạo đơn → **Nhận dòng này** ở [Đối soát xe của tôi](#/acc/mine) |
| Khách đổi pháp nhân sau khi có nháp | — | **Yêu cầu sửa**, chọn pháp nhân mới; kế toán lập nháp mới (v2) |

> Vẫn chưa xử lý được → gửi [Claim & hỏi đáp](#/tickets), ghi mã yêu cầu / mã đơn và chụp màn hình.` },
];

export function HdGuide() {
  return <GuidePage title="Hướng dẫn quy trình · Kế toán – Hóa đơn" secs={HD} roles={['Sale', 'Kế toán', 'Quản lý', 'Admin']}
    intro={<><b className="text-ink-900">Quy trình hóa đơn đầu vào – đầu ra APT</b> từ lúc xe chạy đến khi khách nhận HĐ đã ký. Chọn bộ phận của bạn để xem phần liên quan, hoặc gõ từ khóa để tra nhanh.</>} />;
}

// =====================================================================
// 2) HƯỚNG DẪN TỔNG QUAN HỆ THỐNG THEO BỘ PHẬN
// =====================================================================
const SYS: GuideSec[] = [
  { id: 'bat-dau', icon: '🚀', title: 'Bắt đầu sử dụng', who: ['Tất cả'], text: `
1. **Tài khoản**: Admin / BGĐ tạo tài khoản và gửi bạn email + mật khẩu tạm. Không có tự đăng ký.
2. Đăng nhập lần đầu → vào [Tài khoản của tôi](#/account) → **Đổi mật khẩu**, khai **tài khoản nhận lương**.
3. **Cài lên điện thoại** như ứng dụng: iPhone mở bằng Safari → nút Chia sẻ → "Thêm vào MH chính"; Android / máy tính dùng Chrome → menu ⋮ → "Cài đặt ứng dụng". Sau đó bấm **Bật thông báo** ở trang Tài khoản.
4. **Menu bên trái** chia nhóm (Bán hàng, Nhân sự, Kế toán – Hóa đơn, Vận hành, Quản trị). Bấm tên nhóm để mở / thu gọn; nhóm của trang đang dùng luôn mở sẵn. Trên điện thoại bấm nút ☰ góc trái.
5. **Chuông 🔔** góc phải: thông báo duyệt đơn, báo giá, hóa đơn… Bấm vào thông báo để tới đúng chỗ.

> Mỗi người chỉ thấy menu đúng quyền của mình. Thiếu menu cần dùng → báo quản lý trực tiếp hoặc Admin.` },

  { id: 'moi-nguoi', icon: '🌞', title: 'Việc hằng ngày của mọi nhân sự', who: ['Tất cả'], text: `
### Trang Hôm nay
- Mở hệ thống là vào [Hôm nay](#/): ai vắng hôm nay / ngày mai / những ngày tới, sinh nhật trong tháng.
- Nút **📷 Chấm công vào / ra** ngay trên trang (điện thoại: nút xanh lớn trên cùng). Hệ thống tự biết lần này là chấm vào hay chấm ra.
- Nút **Xin nghỉ / báo vắng** để gửi đơn nhanh.

### Chấm công — [Chấm công](#/hr/attendance)
1. Lần đầu bấm **Tôi đồng ý** lưu ảnh chấm công (ảnh nén nhỏ, chỉ bạn, quản lý trực tiếp và HCNS xem, tự xóa sau một thời gian).
2. Bấm **Chấm công vào** → chụp selfie → **Xác nhận chấm công**. Giờ chấm lấy theo **máy chủ**, không theo đồng hồ điện thoại.
3. Cuối ngày bấm **Chấm công ra** như trên.
- Phải dùng **wifi văn phòng**. Ngoài mạng công ty: tùy cấu hình sẽ bị chặn hoặc chờ quản lý xác nhận.
- Đi muộn / về sớm trừ vào **quỹ linh hoạt** phút mỗi tháng (xem thanh tiến độ ở trang Chấm công).
- **Quên chấm** → tab **Đơn công**: "Quên chấm đến" (điền giờ vào) hoặc "Quên chấm về" (điền giờ về), chọn đúng ngày — gửi được cho ngày đã qua.
- Lịch **Kho** hoặc **Không chấm công**: không cần chấm bằng ứng dụng, nút chấm công sẽ không hiện.

### Nghỉ phép — [Xin nghỉ](#/hr/leave)
- Chọn loại nghỉ, ngày / buổi / theo giờ, lý do (lý do **chỉ quản lý duyệt và HCNS thấy**), người hỗ trợ khi vắng, bàn giao.
- Không đủ phép → chọn "Nghỉ không lương" cho phần thiếu. Xem sổ phép ở [Bảng công · Chuyên cần](#/hr/timesheet).
- Theo dõi đơn của mình ở [Duyệt đơn](#/hr/approvals) (nhân viên chỉ xem trạng thái).

### Khác
- [Phiếu lương](#/hr/payslips): xem và **xác nhận** phiếu lương mỗi kỳ.
- [Bảng tin](#/news): thông báo công ty. [Claim & hỏi đáp](#/tickets): gửi claim, đề xuất, câu hỏi cho Quản trị (dán ảnh chụp màn hình bằng Ctrl+V).
- [Câu trả lời mẫu](#/crm/replies), [Kho báo giá](#/crm/library), [Tồn kho](#/inventory): tra cứu dùng chung.` },

  { id: 'sale', icon: '💼', title: 'Kinh doanh (Sale / Chuyên viên KD)', who: ['Sale'], text: `
### Một ngày làm việc chuẩn
1. **08:00** Chấm công vào ở trang Hôm nay.
2. Mở [Bảng điều khiển](#/dashboard): **Cần chăm hôm nay**, báo giá chờ phản hồi, thông báo.
3. Gọi / nhắn khách đến hạn → bấm **Ghi chăm sóc nhanh** (góc trên) ghi kết quả ngay sau mỗi cuộc.
4. Có khách mới → bấm **Kiểm tra SĐT / MST** trước khi tạo, tránh trùng khách của người khác.
5. Làm báo giá ở [Báo giá](#/crm/quotes) (tham khảo [Kho báo giá](#/crm/library) để lấy HS, thuế, giá đã chốt).
6. Hóa đơn: xử lý [Hóa đơn của tôi](#/hd) — ưu tiên tab **Chờ tôi duyệt nháp**.
7. **Trước 18:00** nộp [Báo cáo ngày](#/crm/daily) (số tiếp cận, kết nối, báo giá hệ thống tự đếm từ nhật ký).

### Khách hàng — [Khách hàng](#/crm/customers)
- Tìm theo tên, SĐT, MST, mã KH, **username hệ thống**. Lọc "Chỉ khách đến hạn" để chăm đúng lịch.
- Khách trùng / đang có chủ thì hệ thống chặn — không tự tạo bản sao.
- Nhờ hỗ trợ gắn với 1 khách: mở hồ sơ khách → nút hỗ trợ; xem trao đổi ở [Hỗ trợ khách](#/support).

### Báo giá — [Báo giá](#/crm/quotes)
- Nhập dòng hàng, giá NCC, cân nặng; hệ thống tự tính cước, thuế NK, VAT, giá xuất.
- Giá dưới **khung CẤM** không gửi được; dưới **khung DUYỆT** chuyển Trưởng phòng duyệt.
- Có **bản in / PDF** kèm mã QR chuyển khoản, và **Bảng khai gửi APT**.

### KPI
- [Báo cáo và KPI](#/crm/reports): phễu khách theo giai đoạn, KPI của mình.
- [Bảng Phong Thần](#/kpi): xếp hạng theo điểm KPI hoạt động và lợi nhuận. Nhóm cuối bảng được ưu tiên hỗ trợ 1:1, không bị phạt.
> Quy trình hóa đơn chi tiết: [Hướng dẫn quy trình Kế toán – Hóa đơn](#/hd/guide).` },

  { id: 'quan-ly', icon: '🧑‍💼', title: 'Trưởng nhóm / Trưởng phòng / Quản lý trực tiếp', who: ['Quản lý'], text: `
- [Duyệt đơn](#/hr/approvals): duyệt / từ chối đơn nghỉ, đơn công của cấp dưới (từ chối phải ghi lý do). **Tạo đơn hộ** khi nhân viên báo nghỉ qua điện thoại (đơn hộ được duyệt ngay).
- **Ủy quyền duyệt** khi mình vắng (tối đa 30 ngày) — người được ủy quyền duyệt đơn cấp dưới của bạn trong thời gian đó.
- [Báo cáo ngày](#/crm/daily): nhận xét báo cáo của nhóm (nhận xét xong báo cáo khóa), xác nhận bài FB đạt / không đạt.
- [Báo cáo và KPI](#/crm/reports): KPI theo nhân viên, đối chiếu **tự khai với hệ thống ghi nhận** để phát hiện ghi chép thiếu.
- Trưởng phòng KD: **duyệt giá báo giá** phá khung (từ trang Duyệt đơn → "Báo giá chờ duyệt giá").
- Hóa đơn: duyệt giá biên > 4% và theo dõi tồn HĐ ở [Duyệt giá & tồn HĐ](#/hd/ql).
- [Chấm công](#/hr/attendance) → tab **Bảng chấm công nhân sự**: xác nhận lượt chấm ngoài mạng công ty.

### Nhịp quản lý gợi ý
| Khi nào | Việc |
| Mỗi sáng | Duyệt đơn tồn, xem ai vắng, khách đến hạn của nhóm |
| 18:00 | Kiểm báo cáo ngày, nhận xét trong ngày |
| Thứ 2 | Xem KPI tuần, Bảng Phong Thần, tồn HĐ đầu vào theo sale |
| Cuối tháng | Kiểm bảng công nhóm trước khi HCNS chốt lương |` },

  { id: 'ke-toan', icon: '🧮', title: 'Kế toán', who: ['Kế toán'], text: `
- **Hóa đơn**: làm theo [Bàn làm việc kế toán](#/hd/kt) — 4 khối theo thứ tự trong ngày. Chi tiết: [Hướng dẫn quy trình](#/hd/guide?s=ke-toan).
- [Danh sách xe đối soát](#/acc): tất cả xe, HĐ đầu vào, theo dõi HĐ đầu vào, ghép tên sale.
- [Bảng lương](#/hr/payroll): nhập file **"BC Lợi nhuận"** (.xlsx) từ hệ thống đơn hàng để tính hoa hồng; tên sale trong file chưa khớp → thêm "Tên trong file đơn" cho đúng người rồi nhập lại.
- [Cấu hình](#/admin/settings): **Báo giá & tỷ giá**, **Công ty & VietQR**, **Kế toán – Hóa đơn**.
- [Chứng từ](#/docs): lưu chứng từ XNK; mỗi lần mở đều ghi nhật ký.` },

  { id: 'hcns', icon: '🗂️', title: 'Hành chính – Nhân sự (HCNS)', who: ['HCNS'], text: `
- [Hồ sơ nhân sự](#/hr/staff): thông tin nhân sự, hợp đồng, phòng ban.
- [Duyệt đơn](#/hr/approvals): HCNS duyệt được đơn của mọi người (trừ đơn của chính mình), tạo đơn hộ.
- [Bảng công · Chuyên cần](#/hr/timesheet): bảng công tháng, sổ phép năm (nhập số đã dùng trước khi lên hệ thống).
- [Bảng lương](#/hr/payroll): tính lương → gửi nhân sự xác nhận → chốt. Điều chỉnh (thưởng nóng, BHXH, tạm ứng — số âm là khoản trừ) đều ghi nhật ký.
- [Cấu hình](#/admin/settings): **Chấm công & lịch** (giờ làm, IP văn phòng, quỹ linh hoạt), **Ngày lễ**, **Màn hình đăng nhập**.
!> Từ bản 26, **tạo tài khoản / phân quyền** và **Dữ liệu · Nhật ký** chỉ Admin / BGĐ dùng. Cần tạo tài khoản cho nhân sự mới → gửi thông tin cho Admin / BGĐ.` },

  { id: 'phong-khac', icon: '📦', title: 'Kho và các phòng khác', who: ['Phòng khác'], text: `
- Lịch **Kho (T2–T7)** không chấm công bằng ứng dụng — nút chấm công không hiện; vẫn xin nghỉ, xem phiếu lương bình thường.
- [Tồn kho](#/inventory): tra tồn theo tên (không cần dấu) hoặc mã. Nên nhập file tồn từ phần mềm kho mỗi ngày / tuần; mọi thay đổi số tồn / giá được ghi nhật ký.
- [Claim & hỏi đáp](#/tickets): báo sự cố hàng hóa, claim khách, đề xuất cải tiến.
- [Hỗ trợ khách](#/support): nhận yêu cầu hỗ trợ từ sale, ghi đã làm gì và kết quả.` },

  { id: 'admin', icon: '🛡️', title: 'Admin / Ban giám đốc', who: ['Admin'], text: `
- [Nhân sự & phân quyền](#/admin/users) — **chỉ Admin / BGĐ**: tạo tài khoản (email + mật khẩu tạm), cấp bậc, vai trò, quản lý trực tiếp (người duyệt đơn), phòng ban, lịch làm việc, "Nhân viên mới (KPI × 0,7)".
- [Dữ liệu · Nhật ký](#/admin/data) — **chỉ Admin / BGĐ**: ảnh chấm công, sao lưu & khôi phục, danh sách khách đang chạy của công ty (thay toàn bộ mỗi tháng), nhật ký hệ thống.
- [Cấu hình](#/admin/settings): Telegram, sao lưu Google Drive, Lương & KPI, tham số CRM, danh mục, phòng ban, người duyệt mở chặn HĐ.

### Sao lưu
- Mỗi lần nâng cấp hệ thống tự tạo bản sao lưu trước khi đổi. Tải file sao lưu (.zip) định kỳ và cất lên Google Drive.

### Vai trò trong hệ thống
| Vai trò | Dùng cho |
| Admin hệ thống / Ban giám đốc | Toàn quyền, phân quyền, dữ liệu |
| HCNS | Nhân sự, chấm công, nghỉ phép, lương |
| Kế toán | Hóa đơn, đối soát, lương, cấu hình báo giá |
| Trưởng phòng KD / Trưởng nhóm KD | Quản lý sale cấp dưới, duyệt |
| Sale | CRM, báo giá, hóa đơn của mình |
| Nhân viên (phòng khác) | Chấm công, nghỉ phép, tra cứu chung |` },

  { id: 'quyen', icon: '🔑', title: 'Ai xem được dữ liệu gì', who: ['Tất cả'], text: `
- Sale thấy khách, báo giá, KPI, công, phiếu lương **của mình**; Trưởng nhóm / Trưởng phòng thấy của **toàn bộ cấp dưới** (theo "Quản lý trực tiếp").
- **Lương**: chính chủ, quản lý cấp trên, HCNS, Kế toán, BGĐ.
- **Chứng từ**: Chuyên viên trở lên và Kế toán.
- **Hóa đơn PDF**: sale của yêu cầu, cấp trên, Kế toán, Admin, BGĐ — không xem chéo giữa các sale.
- **Lý do xin nghỉ**: chỉ quản lý duyệt và HCNS.
> Quyền được kiểm ở máy chủ, không chỉ ẩn nút — gõ thẳng địa chỉ trang cũng không vào được mục không có quyền.` },

  { id: 'faq', icon: '❓', title: 'Câu hỏi thường gặp', who: ['Tất cả'], text: `
| Câu hỏi | Trả lời |
| Quên chấm công vào / ra? | [Chấm công](#/hr/attendance) → tab **Đơn công** → chọn "Xác nhận chấm công muộn (quên chấm đến)" hoặc "Xác nhận quên chấm công về", điền ngày + giờ. Quản lý duyệt / sửa giờ → giờ đó dùng tính đi muộn, lương. Gửi được cho ngày trong 30 ngày; mỗi tháng có giới hạn số lần |
| Báo "ngoài mạng công ty"? | Kết nối wifi văn phòng rồi bấm lại. Đi gặp khách → tạo đơn công tác |
| Camera không mở? | Cho phép quyền camera cho trang; vẫn lỗi thì chọn ảnh từ máy trong hộp chấm công |
| Không thấy một menu? | Menu hiện theo quyền. Cần dùng → báo quản lý / Admin |
| Quên mật khẩu? | Báo Admin đặt lại; đăng nhập xong đổi mật khẩu ở Tài khoản |
| Không nhận thông báo trên điện thoại? | Cài app lên màn hình chính rồi bấm **Bật thông báo** ở [Tài khoản](#/account). Chuông 🔔 trong app luôn có đủ |
| Đơn nghỉ đã duyệt muốn hủy? | Hủy được trước ngày nghỉ; tới ngày rồi thì liên hệ HCNS |` },
];

export function SystemGuide() {
  return <GuidePage title="Hướng dẫn tổng quan" secs={SYS} roles={['Sale', 'Quản lý', 'Kế toán', 'HCNS', 'Phòng khác', 'Admin']}
    intro={<><b className="text-ink-900">Hướng dẫn sử dụng ERP Nam Trung theo từng bộ phận.</b> Chọn bộ phận của bạn để xem việc cần làm, hoặc gõ từ khóa để tra nhanh. Quy trình hóa đơn xem riêng ở <a className="font-semibold text-brand-700" href="#/hd/guide">Hướng dẫn quy trình Kế toán – Hóa đơn</a>.</>} />;
}
