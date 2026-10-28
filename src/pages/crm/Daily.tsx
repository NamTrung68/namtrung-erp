import React, { useState } from 'react';
import { Layout } from '../../components/Layout';
import { Badge, Button, Card, Empty, Field, Input, Loading, NumInput, Table, Td, Textarea, useAction, useLoad } from '../../components/ui';
import { db } from '../../lib/sb';
import { useApp } from '../../state';
import { fmtDate, fmtDateTime, today, addDays } from '../../lib/format';

export default function Daily() {
  const a = useApp();
  const [f, setF] = useState({ calls: null as number | null, messages: null as number | null, content: '', plan_tomorrow: '' });
  const [url, setUrl] = useState('');
  const { busy, run } = useAction();
  const from = addDays(today(), -14);
  const { data: reps, loading, reload } = useLoad(() => db.from('daily_reports').select('*').gte('report_date', from).order('report_date', { asc: false }).order('submitted_at', { asc: false }).limit(300), []);
  const { data: posts, reload: reloadPosts } = useLoad(() => db.from('fb_posts').select('*').gte('post_date', from).order('created_at', { asc: false }).limit(300), []);
  const mineToday = (reps as any[] || []).find(r => r.sale_id === a.me.id && r.report_date === today());
  const submit = () => run(async () => {
    if (f.content.trim().length < 10) throw new Error('Viết nội dung báo cáo (tối thiểu 10 ký tự)');
    await db.from('daily_reports').insert({ calls: f.calls ?? 0, messages: f.messages ?? 0, content: f.content, plan_tomorrow: f.plan_tomorrow || null });
    reload();
  }, 'Đã nộp báo cáo ngày');
  const addPost = () => run(async () => { await db.from('fb_posts').insert({ url: url.trim() }); setUrl(''); reloadPosts(); }, 'Đã ghi bài FB — chờ quản lý xác nhận');
  const verify = (id: string) => run(async () => { await db.from('fb_posts').update({ verified_by: a.me.id, verified_at: new Date().toISOString() }).eq('id', id); reloadPosts(); }, 'Đã xác nhận');
  const review = (id: string) => run(async () => { await db.from('daily_reports').update({ reviewed_by: a.me.id }).eq('id', id); reload(); }, 'Đã duyệt');
  return (
    <Layout title="Báo cáo ngày · Bài FB">
      <div className="grid gap-4 lg:grid-cols-2">
        <Card title={`Báo cáo ngày ${fmtDate(today())}`}>
          {mineToday ? <div className="text-sm"><Badge color={mineToday.on_time ? 'green' : 'amber'}>{mineToday.on_time ? 'Đã nộp đúng hạn' : 'Nộp trễ'}</Badge> lúc {fmtDateTime(mineToday.submitted_at)}
            <p className="mt-2 whitespace-pre-wrap">{mineToday.content}</p></div> :
            <div className="space-y-3">
              <div className="grid grid-cols-2 gap-3">
                <Field label="Số cuộc gọi tự khai"><NumInput value={f.calls} onChange={v => setF({ ...f, calls: v })} /></Field>
                <Field label="Số tin nhắn tự khai"><NumInput value={f.messages} onChange={v => setF({ ...f, messages: v })} /></Field>
              </div>
              <Field label="Kết quả trong ngày, khó khăn, cần hỗ trợ"><Textarea rows={4} value={f.content} onChange={e => setF({ ...f, content: e.target.value })} /></Field>
              <Field label="Kế hoạch ngày mai"><Textarea rows={2} value={f.plan_tomorrow} onChange={e => setF({ ...f, plan_tomorrow: e.target.value })} /></Field>
              <p className="text-xs text-ink-500">Số tiếp cận, kết nối, báo giá được hệ thống tự đếm từ nhật ký — không cần khai. Hạn nộp 18:00.</p>
              <Button variant="primary" loading={busy} onClick={submit}>Nộp báo cáo</Button>
            </div>}
        </Card>
        <Card title="Bài Facebook chính ngạch (chỉ tiêu 2 bài/ngày)">
          <div className="flex gap-2"><Input placeholder="Dán link bài đăng https://facebook.com/…" value={url} onChange={e => setUrl(e.target.value)} /><Button variant="dark" loading={busy} onClick={addPost}>Ghi</Button></div>
          <ul className="mt-3 divide-y divide-ink-100 text-sm">{(posts as any[] || []).slice(0, 40).map(p => <li key={p.id} className="flex items-center justify-between gap-2 py-2">
            <span className="min-w-0"><a className="block truncate text-brand-700" href={p.url} target="_blank" rel="noreferrer">{p.url}</a><span className="text-xs text-ink-400">{fmtDate(p.post_date)} · {a.personName(p.sale_id)}</span></span>
            {p.verified_at ? <Badge color="green">Đã xác nhận</Badge> : a.isLead && p.sale_id !== a.me.id ? <Button size="sm" onClick={() => verify(p.id)}>Xác nhận</Button> : <Badge>Chờ xác nhận</Badge>}</li>)}</ul>
        </Card>
      </div>
      <Card title="Báo cáo 14 ngày gần nhất" className="mt-4" bodyClass="p-0">
        {loading ? <Loading /> : !(reps as any[])?.length ? <Empty /> :
          <Table head={['Ngày', 'Nhân viên', 'Gọi / Nhắn', 'Nội dung', 'Kế hoạch', 'Trạng thái', '']}>
            {(reps as any[]).map(r => <tr key={r.id}><Td className="whitespace-nowrap">{fmtDate(r.report_date)}</Td><Td className="whitespace-nowrap">{a.personName(r.sale_id)}</Td><Td>{r.calls} / {r.messages}</Td>
              <Td className="max-w-md whitespace-pre-wrap">{r.content}</Td><Td className="max-w-xs whitespace-pre-wrap text-xs">{r.plan_tomorrow}</Td>
              <Td><Badge color={r.on_time ? 'green' : 'amber'}>{r.on_time ? 'Đúng hạn' : 'Trễ'}</Badge>{r.reviewed_by && <div className="text-[11px] text-ink-400">Đã duyệt</div>}</Td>
              <Td>{a.isLead && r.sale_id !== a.me.id && !r.reviewed_by && <Button size="sm" onClick={() => review(r.id)}>Duyệt</Button>}</Td></tr>)}
          </Table>}
      </Card>
    </Layout>
  );
}
