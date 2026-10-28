import React, { useEffect, useState } from 'react';
import { Layout } from '../../components/Layout';
import { Badge, Button, Card, cx, Empty, Field, Input, Loading, NumInput, Table, Td, Tabs, Textarea, useAction, useLoad } from '../../components/ui';
import { db } from '../../lib/sb';
import { useApp } from '../../state';
import { addDays, fmtDate, fmtTime, num, today } from '../../lib/format';

const scoreColor = (s: number) => s >= 100 ? 'bg-emerald-100 text-emerald-800' : s >= 85 ? 'bg-sky-100 text-sky-800' : s >= 70 ? 'bg-amber-100 text-amber-800' : 'bg-red-100 text-red-700';

export default function Daily() {
  const a = useApp(); const [tab, setTab] = useState(a.isLead ? 'team' : 'mine');
  return (
    <Layout title="Báo cáo ngày">
      {a.isLead && <div className="mb-3"><Tabs value={tab} onChange={setTab} tabs={[['team', 'Duyệt báo cáo nhóm'], ['mine', 'Báo cáo của tôi']]} /></div>}
      {tab === 'team' ? <Team /> : <Mine />}
    </Layout>
  );
}

function Team() {
  const a = useApp(); const [d, setD] = useState(today()); const { run } = useAction();
  const { data: kpi, loading } = useLoad(() => db.rpc<any[]>('kpi_report', { p_from: d, p_to: d }), [d]);
  const { data: reps, reload } = useLoad(() => db.from('daily_reports').select('*').eq('report_date', d), [d]);
  const rmap = new Map(((reps as any[]) || []).map(r => [r.sale_id, r]));
  const rows = ((kpi as any[]) || []).filter(k => k.profile_id !== a.me.id || a.isAdmin);
  const review = (r: any, patch: any) => run(async () => { await db.from('daily_reports').update(patch).eq('id', r.id); reload(); });
  const code = (id: string) => a.people.find(p => p.id === id)?.employee_code;
  return (
    <>
      <div className="mb-3 flex flex-wrap items-center gap-3"><span className="text-sm font-semibold">Ngày</span><Input type="date" className="w-44" value={d} onChange={e => setD(e.target.value)} />
        <span className="text-xs text-ink-500">Xác nhận bài FB đúng chủ đề chính ngạch, đăng công khai, đúng ngày. "Không đạt" sẽ trừ điểm FB của ngày đó.</span></div>
      <Card bodyClass="p-0">{loading ? <Loading /> : !rows.length ? <Empty>Không có nhân viên trong nhóm</Empty> :
        <Table head={['Nhân viên', 'Nộp lúc', 'Điểm', 'KH mới', 'Tiếp cận', 'Kết nối', 'Chăm cũ', 'BG', 'Gọi (nhật ký / tự khai)', 'Bài FB', 'Kế hoạch mai / khó khăn', 'FB', 'Nhận xét']}>
          {rows.map(k => {
            const r: any = rmap.get(k.profile_id); const m = k.metrics;
            return <tr key={k.profile_id}>
              <Td className="whitespace-nowrap"><b>{k.full_name}</b><div className="text-xs text-ink-400">{code(k.profile_id)}</div></Td>
              <Td className="whitespace-nowrap">{r ? <>{fmtTime(r.submitted_at)}{!r.on_time && <Badge color="amber" className="ml-1">Trễ</Badge>}</> : <span className="text-red-600">Chưa nộp</span>}</Td>
              <Td><span className={cx('inline-block min-w-[2.5rem] rounded-md px-2 py-0.5 text-center text-sm font-bold', scoreColor(Number(k.score)))}>{num(k.score, 1)}</span></Td>
              {['kh_moi', 'tiep_can', 'ket_noi', 'cham_cu', 'bao_gia'].map(x => <Td key={x} className="text-center tabular-nums">{m[x]}</Td>)}
              <Td className="whitespace-nowrap text-center">{m.cuoc_goi_nhat_ky} / {r ? r.calls : '–'}</Td>
              <Td className="text-xs">{r?.fb_links?.length ? r.fb_links.map((u: string, i: number) => <a key={i} className="block text-brand-700 underline" href={u} target="_blank" rel="noreferrer">Bài {i + 1}</a>) : '–'}</Td>
              <Td className="min-w-[200px] max-w-xs whitespace-pre-wrap text-xs">{r ? <>{r.plan_tomorrow}{r.content && <div className="mt-1 text-ink-500">{r.content}</div>}</> : ''}</Td>
              <Td className="whitespace-nowrap">{r?.fb_links?.length ? <div className="flex gap-1">
                <Button size="sm" variant={r.fb_status === 'dat' ? 'success' : 'secondary'} onClick={() => review(r, { fb_status: 'dat' })}>Đạt</Button>
                <Button size="sm" variant={r.fb_status === 'khong_dat' ? 'danger' : 'secondary'} onClick={() => review(r, { fb_status: 'khong_dat' })}>Không đạt</Button></div> : ''}</Td>
              <Td className="min-w-[180px]">{r && <Input defaultValue={r.review_note || ''} placeholder="Nhận xét…" onBlur={e => e.target.value !== (r.review_note || '') && review(r, { review_note: e.target.value })} />}</Td>
            </tr>;
          })}
        </Table>}
      </Card>
    </>
  );
}

function Mine() {
  const a = useApp(); const { busy, run } = useAction(); const d = today();
  const { data: kpi } = useLoad(() => db.rpc<any[]>('kpi_report', { p_from: d, p_to: d }), []);
  const { data: reps, reload } = useLoad(() => db.from('daily_reports').select('*').eq('sale_id', a.me.id).gte('report_date', addDays(d, -14)).order('report_date', { asc: false }), []);
  const cur = ((reps as any[]) || []).find(r => r.report_date === d);
  const me = ((kpi as any[]) || []).find(k => k.profile_id === a.me.id);
  const [f, setF] = useState({ calls: null as number | null, messages: null as number | null, links: '', content: '', plan_tomorrow: '' });
  useEffect(() => { if (cur) setF({ calls: cur.calls, messages: cur.messages, links: (cur.fb_links || []).join('\n'), content: cur.content, plan_tomorrow: cur.plan_tomorrow || '' }); }, [cur?.id]);
  const save = () => run(async () => {
    if (f.content.trim().length < 10) throw new Error('Ghi kết quả / khó khăn trong ngày (tối thiểu 10 ký tự)');
    const links = f.links.split(/\s+/).map(x => x.trim()).filter(x => /^https?:\/\//i.test(x));
    const body = { calls: f.calls ?? 0, messages: f.messages ?? 0, content: f.content.trim(), plan_tomorrow: f.plan_tomorrow || null, fb_links: links };
    if (cur) await db.from('daily_reports').update(body).eq('id', cur.id); else await db.from('daily_reports').insert(body);
    reload();
  }, cur ? 'Đã cập nhật báo cáo' : 'Đã nộp báo cáo ngày');
  const m = me?.metrics || {};
  return (
    <div className="grid gap-4 lg:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]">
      <Card title={`Báo cáo ngày ${fmtDate(d)}`} actions={cur && <Badge color={cur.on_time ? 'green' : 'amber'}>{cur.on_time ? 'Đã nộp đúng hạn' : 'Nộp trễ'} {fmtTime(cur.submitted_at)}</Badge>}>
        <div className="mb-4 grid grid-cols-3 gap-2 sm:grid-cols-6">
          {[['KH mới', m.kh_moi], ['Tiếp cận', m.tiep_can], ['Kết nối', m.ket_noi], ['Chăm cũ', m.cham_cu], ['Báo giá', m.bao_gia], ['Điểm', num(me?.score, 1)]].map(([l, v]) =>
            <div key={l as string} className="rounded-xl bg-ink-50 p-2 text-center"><div className="text-lg font-extrabold">{v ?? 0}</div><div className="text-[11px] text-ink-500">{l}</div></div>)}
        </div>
        {cur?.reviewed_by ? <p className="text-sm text-ink-600">Quản lý đã nhận xét — báo cáo đã khóa.</p> : <div className="space-y-3">
          <div className="grid grid-cols-2 gap-3"><Field label="Cuộc gọi (tự khai)"><NumInput value={f.calls} onChange={v => setF({ ...f, calls: v })} /></Field>
            <Field label="Tin nhắn (tự khai)"><NumInput value={f.messages} onChange={v => setF({ ...f, messages: v })} /></Field></div>
          <Field label="Link bài FB chính ngạch hôm nay (mỗi dòng 1 link, chỉ tiêu 2 bài)"><Textarea rows={2} value={f.links} onChange={e => setF({ ...f, links: e.target.value })} placeholder="https://facebook.com/…" /></Field>
          <Field label="Kết quả trong ngày, khó khăn, cần hỗ trợ" required><Textarea rows={3} value={f.content} onChange={e => setF({ ...f, content: e.target.value })} /></Field>
          <Field label="Kế hoạch ngày mai"><Textarea rows={2} value={f.plan_tomorrow} onChange={e => setF({ ...f, plan_tomorrow: e.target.value })} /></Field>
          <p className="text-xs text-ink-500">Tiếp cận, kết nối, báo giá hệ thống tự đếm từ nhật ký. Hạn nộp 18:00. Sửa được tới khi quản lý nhận xét.</p>
          <Button variant="primary" loading={busy} onClick={save}>{cur ? 'Cập nhật báo cáo' : 'Nộp báo cáo'}</Button>
        </div>}
      </Card>
      <Card title="14 ngày gần nhất" bodyClass="p-0">{!(reps as any[])?.length ? <Empty /> :
        <Table head={['Ngày', 'Nộp', 'FB', 'Nhận xét']}>{(reps as any[]).map(r => <tr key={r.id}><Td className="whitespace-nowrap">{fmtDate(r.report_date)}</Td>
          <Td><Badge color={r.on_time ? 'green' : 'amber'}>{r.on_time ? 'Đúng hạn' : 'Trễ'}</Badge></Td>
          <Td>{r.fb_links?.length || 0} bài {r.fb_status && <Badge color={r.fb_status === 'dat' ? 'green' : 'red'}>{r.fb_status === 'dat' ? 'Đạt' : 'Không đạt'}</Badge>}</Td>
          <Td className="text-xs">{r.review_note}</Td></tr>)}</Table>}</Card>
    </div>
  );
}
