-- =====================================================================
-- ERP Nam Trung · 0007 Dữ liệu cấu hình ban đầu (giữ nguyên danh mục CRM)
-- =====================================================================

insert into public.job_levels(code, name, rank, base_salary, commission_pct, team_bonus_pct, is_sales) values
 ('thu_viec',    'Thử việc',        1,  6000000,  8, 0, true),
 ('nhan_vien',   'Nhân viên',       2,  7000000, 12, 0, true),
 ('chuyen_vien', 'Chuyên viên',     3,  8000000, 15, 0, true),
 ('truong_nhom', 'Trưởng nhóm',     4, 12000000, 17, 3, true),
 ('truong_phong','Trưởng phòng',    5, 18000000, 17, 3, true),
 ('giam_doc',    'Giám đốc',        6, 25000000, 17, 3, true)
on conflict (code) do nothing;

insert into public.org_units(id, name, kind, sort) values ('00000000-0000-0000-0000-000000000001', 'Công ty Nam Trung', 'cong_ty', 0) on conflict do nothing;
insert into public.org_units(parent_id, name, kind, sort)
select '00000000-0000-0000-0000-000000000001', x.name, 'phong', x.sort from (values
 ('Kinh doanh',1),('Kế toán',2),('CSKH',3),('XNK',4),('Điều vận',5),('Mua hàng',6),('Kho',7),('Marketing',8),('Hành chính nhân sự',9)) x(name, sort)
where not exists (select 1 from public.org_units o where o.name = x.name);

-- Giai đoạn (extra.cadence = nhịp chăm theo giai đoạn)
insert into public.lookups(category, code, label, sort, extra) values
 ('stage','moi','Mới - Chưa liên hệ',1,'{"cadence":1}'),
 ('stage','tiep_can','Đã tiếp cận',2,'{"cadence":3}'),
 ('stage','khai_thac','Khai thác nhu cầu',3,'{"cadence":3}'),
 ('stage','da_bao_gia','Đã gửi báo giá',4,'{"cadence":2}'),
 ('stage','dam_phan','Đàm phán - Chờ quyết định',5,'{"cadence":2}'),
 ('stage','don_dau','Khách mới (đơn đầu)',6,'{"cadence":3}'),
 ('stage','hoat_dong','Khách đang hoạt động',7,'{"cadence":7}'),
 ('stage','vip','Khách VIP',8,'{"cadence":5}'),
 ('stage','kho_ngu','Kho khách ngủ',9,'{"cadence":14}'),
 ('stage','mat_khach','Mất khách',10,'{"cadence":30}'),
 ('stage','khong_tiem_nang','Không tiềm năng',11,'{"cadence":null}'),
 ('temperature','nong','Nóng',1,'{"cadence":2}'),
 ('temperature','am','Ấm',2,'{"cadence":5}'),
 ('temperature','lanh','Lạnh',3,'{"cadence":14}'),
 ('channel','goi_dien','Gọi điện',1,null),('channel','zalo','Zalo',2,null),('channel','sms','SMS',3,null),
 ('channel','facebook','Facebook/Messenger',4,null),('channel','email','Email',5,null),('channel','gap_truc_tiep','Gặp trực tiếp',6,null),('channel','khac','Khác',7,null),
 ('care_purpose','tiep_can_lan_dau','Tiếp cận lần đầu',1,null),
 ('care_purpose','khai_thac_nhu_cau','Khai thác nhu cầu',2,null),
 ('care_purpose','gui_bao_gia','Gửi báo giá',3,null),
 ('care_purpose','theo_doi_bao_gia','Theo dõi báo giá',4,null),
 ('care_purpose','cham_soc_khach_cu','Chăm sóc khách cũ',5,null),
 ('care_purpose','sau_ban','Chăm sóc sau bán',6,null),
 ('care_purpose','nhac_dat_hang','Nhắc đặt hàng lại',7,null),
 ('care_purpose','khieu_nai','Xử lý phản ánh',8,null),
 ('care_purpose','khac','Khác',9,null),
 ('care_result','khong_nghe_may','Không nghe máy',1,'{"fail":true}'),
 ('care_result','sai_so','Thuê bao/Sai số',2,'{"fail":true}'),
 ('care_result','chua_phan_hoi','Đã nhắn - chưa phản hồi',3,'{"fail":true}'),
 ('care_result','ket_ban_zalo','Đã kết bạn Zalo',4,'{}'),
 ('care_result','co_quan_tam','Trao đổi được - có quan tâm',5,'{"stage":"khai_thac","temp":"am"}'),
 ('care_result','chua_nhu_cau','Trao đổi được - chưa có nhu cầu',6,'{"temp":"lanh"}'),
 ('care_result','dung_don_vi_khac','Đang dùng đơn vị khác',7,'{"temp":"lanh"}'),
 ('care_result','hen_goi_lai','Hẹn gọi lại',8,'{"temp":"am"}'),
 ('care_result','xin_bao_gia','Xin báo giá',9,'{"stage":"khai_thac","temp":"nong"}'),
 ('care_result','che_gia_cao','Chê giá cao',10,'{"stage":"dam_phan","temp":"am"}'),
 ('care_result','dong_y_chot','Đồng ý chốt đơn',11,'{"temp":"nong","hint":"Nhớ chuyển báo giá sang Đã chốt đơn"}'),
 ('care_result','phan_anh','Phản ánh/Khiếu nại',12,'{}'),
 ('care_result','hai_long','Hài lòng sau giao hàng',13,'{}'),
 ('care_result','tu_choi_han','Từ chối hẳn',14,'{"temp":"lanh"}'),
 ('customer_type','shop_tmdt','Shop TMĐT',1,null),('customer_type','shop_offline','Shop offline',2,null),
 ('customer_type','nha_buon','Nhà bán buôn',3,null),('customer_type','nha_may','Nhà máy/Xưởng sản xuất',4,null),
 ('customer_type','cong_ty_nk','Công ty nhập khẩu/Thương mại',5,null),('customer_type','sme','Doanh nghiệp SME',6,null),
 ('customer_type','co_so_sx','Cơ sở sản xuất nhỏ',7,null),('customer_type','ca_nhan','Cá nhân',8,null),('customer_type','dai_ly','Đối tác/Đại lý',9,null),
 ('source','tu_tim_zalo','Tự tìm - Zalo/Group',1,null),('source','tu_tim_fb','Tự tìm - Facebook',2,null),('source','tu_tim_khac','Tự tìm - Khác',3,null),
 ('source','marketing','Marketing (inbox/hotline)',4,null),('source','gioi_thieu','Khách giới thiệu',5,null),('source','cong_ty_giao','Công ty giao',6,null),
 ('source','kho_khach_ngu','Kho khách ngủ',7,null),('source','su_kien','Sự kiện/Hội chợ',8,null),('source','khac','Khác',9,null),
 ('import_method','tron_goi_cn','Trọn gói chính ngạch - Nam Trung xuất HĐ VAT',1,null),
 ('import_method','uy_thac','Ủy thác nhập khẩu',2,null),
 ('import_method','tu_dung_ten','KH tự đứng tên NK (thuê VC + khai HQ)',3,null),
 ('import_method','mua_ho','Chỉ mua hộ/thanh toán hộ',4,null),
 ('import_method','vc_khong_hd','Vận chuyển không hóa đơn',5,null),
 ('import_method','tieu_ngach','Tiểu ngạch (đang chuyển dịch)',6,null),
 ('import_method','chua_xac_dinh','Chưa xác định',7,null),
 ('legal_entity','ca_nhan','Cá nhân',1,null),('legal_entity','ho_kinh_doanh','Hộ kinh doanh',2,null),('legal_entity','doanh_nghiep','Doanh nghiệp',3,null),
 ('invoice_need','can_vat','Cần HĐ VAT',1,null),('invoice_need','khong_can','Không cần hóa đơn',2,null),('invoice_need','chua_ro','Chưa rõ',3,null),
 ('frequency','chua_ro','Chưa rõ',1,null),('frequency','hang_tuan','Hằng tuần',2,null),('frequency','hang_thang','Hằng tháng',3,null),('frequency','theo_mua','Theo mùa',4,null),('frequency','le','Lẻ tẻ',5,null),
 ('monthly_value','duoi_50','Dưới 50 triệu',1,null),('monthly_value','50_200','50-200 triệu',2,null),('monthly_value','200_500','200-500 triệu',3,null),
 ('monthly_value','500_1ty','500 triệu - 1 tỷ',4,null),('monthly_value','tren_1ty','Trên 1 tỷ',5,null),
 ('industry','thoi_trang','Thời trang - Phụ kiện',1,null),('industry','gia_dung','Gia dụng',2,null),('industry','dien_tu','Điện tử - Phụ kiện',3,null),
 ('industry','may_moc','Máy móc - Thiết bị',4,null),('industry','nguyen_lieu','Nguyên phụ liệu sản xuất',5,null),('industry','vpp','Văn phòng phẩm',6,null),
 ('industry','my_pham','Mỹ phẩm',7,null),('industry','do_choi','Đồ chơi',8,null),('industry','noi_that','Nội thất',9,null),('industry','khac','Khác',10,null),
 ('service','mua_ho','Mua hộ',1,null),('service','thanh_toan_ho','Thanh toán hộ',2,null),('service','nk_chinh_ngach','Nhập khẩu chính ngạch',3,null),
 ('service','nk_tieu_ngach','Nhập khẩu tiểu ngạch',4,null),('service','van_chuyen','Vận chuyển TQ-VN',5,null),('service','khai_hq','Khai báo hải quan',6,null),
 ('service','logistics','Logistics trọn gói',7,null),('service','tim_nguon','Tìm nguồn hàng',8,null),('service','ky_gui_cn','Ký gửi chính ngạch',9,null),('service','ky_gui_tn','Ký gửi TN',10,null),
 ('goods_trait','thong_thuong','Hàng thông thường',1,null),('goods_trait','hop_quy','Cần hợp quy/công bố',2,null),('goods_trait','kiem_dich','Kiểm dịch/ATTP',3,null),
 ('goods_trait','giay_phep','Cần giấy phép NK',4,null),('goods_trait','thuong_hieu','Hàng có thương hiệu',5,null),('goods_trait','mau_duoi_100kg','Hàng mẫu < 100kg',6,null),
 ('goods_trait','cong_kenh','Hàng cồng kềnh',7,null),('goods_trait','de_vo','Hàng dễ vỡ',8,null),
 ('reject_reason','gia_cao','Giá cao hơn đối thủ',1,null),('reject_reason','thoi_gian_vc','Thời gian vận chuyển',2,null),
 ('reject_reason','chua_tin','Chưa tin tưởng',3,null),('reject_reason','huy_ke_hoach','Hủy/đổi kế hoạch',4,null),
 ('reject_reason','don_vi_khac','Chọn đơn vị khác',5,null),('reject_reason','giay_phep','Vướng giấy phép',6,null),
 ('reject_reason','khong_phan_hoi','Không phản hồi',7,null),('reject_reason','khac','Khác',8,null),
 ('transfer_reason','nghi_viec','Sale nghỉ việc',1,null),('transfer_reason','can_tai','Cân tải',2,null),('transfer_reason','bo_be','Bỏ bê khách',3,null),
 ('transfer_reason','tu_nha','Sale tự nhả khách',4,null),('transfer_reason','phan_bo_kho_ngu','Phân bổ Kho khách ngủ',5,null),
 ('transfer_reason','chu_cu_dong_y','Chủ cũ đồng ý',6,null),('transfer_reason','khac','Khác',7,null),
 ('leave_type','phep_nam','Phép năm',1,'{"paid":true}'),
 ('leave_type','khong_luong','Nghỉ không lương',2,'{"paid":false}'),
 ('leave_type','om_dau','Nghỉ ốm (BHXH)',3,'{"paid":false}'),
 ('leave_type','che_do','Nghỉ chế độ (cưới, tang...) có lương',4,'{"paid":true}'),
 ('warehouse','HN','Kho Hà Nội',1,null),('warehouse','HCM','Kho HCM',2,null)
on conflict (category, code) do nothing;

insert into public.doc_categories(name, min_rank, sort) values
 ('Tờ khai hải quan',3,1),('Hóa đơn VAT',3,2),('Hợp đồng',3,3),('Hợp quy/Công bố',3,4),('Khác',3,9)
on conflict (name) do nothing;

insert into public.exchange_rates(rate_type, rate, note, created_by) values
 ('ban', 4015, 'Tỷ giá bán chuẩn ban đầu', null),
 ('san', 4015, 'Tỷ giá sàn (dưới mức này cần duyệt)', null),
 ('von', 3955, 'Tỷ giá vốn (dưới mức này cấm)', null);

insert into public.settings(key, value, description) values
 ('quote_defaults', '{"tyGia":4015,"phiDVPct":2,"phiUTPct":1,"vatPct":8,"donGiaKg":7000,"donGiaKhoi":1100000,"lamTron":1,"lamTronKieu":"gan","heSoToKhai":0.9425,"tyLeXuatMin":70,"tndnPct":20,"coSoThueNK":"toKhai","coSoUyThac":"giaXuat","phiUTSan":0.8,"phiDVSan":1.2,"giaVonKhoi":{"HN":800000,"HCM":1300000},"tyLeCoc":80,"hieuLuc":5}', 'Tham số mặc định báo giá'),
 ('crm', '{"company_active_days":60,"dormant_days":90,"quote_valid_days":5,"quote_expire_grace_days":14,"report_deadline_hour":18,"forgotten_days":30}', 'Tham số CRM'),
 ('kpi', '{"new_hire_factor":0.7,"metrics":{"kh_moi":{"label":"KH mới nhập hệ thống","day":15,"weight":15},"tiep_can":{"label":"Tiếp cận lần đầu","day":15,"weight":20},"ket_noi":{"label":"Kết nối thành công","day":6,"weight":20},"cham_cu":{"label":"Chăm sóc khách cũ","day":10,"weight":15},"bao_gia":{"label":"Báo giá gửi khách","day":1,"weight":10},"bai_fb":{"label":"Bài FB chính ngạch","day":2,"weight":10},"bao_cao":{"label":"Báo cáo ngày đúng hạn","day":1,"weight":10}}}', 'Chỉ tiêu KPI giai đoạn tích lũy'),
 ('attendance', '{"start":"08:00","end":"17:30","saturday_end":"12:00","lunch_start":"12:00","lunch_end":"13:30","saturday_value":0.5,"flex_minutes":100,"flex_start":"2026-11-01","forgot_limit":3,"ip_whitelist":[],"require_selfie":true,"selfie_retention_days":60}', 'Chấm công'),
 ('leave', '{"monthly_accrual":1,"annual_days":12,"carry_until":"06-30"}', 'Phép năm'),
 ('payroll', '{"commission_base_pct":60,"tiers":[[0,0],[30000000,3],[65000000,5],[100000000,7]],"loss_offset_max_pct":50}', 'Lương & hoa hồng'),
 ('company', '{"name":"CÔNG TY TNHH DỊCH VỤ VÀ THƯƠNG MẠI QUỐC TẾ NAM TRUNG","short":"Nam Trung","address":"Tòa G4, CC Five Star, 460 Khương Đình, Thanh Xuân, HN","hotline":"0859.59.1688","email":"info@namtrunglog.com","tax_code":"0108195040","website":"namtrunglog.com"}', 'Thông tin công ty in trên báo giá'),
 ('vietqr', '{"bank_bin":"970415","bank_name":"VietinBank - Hà Nội","account":"117634318888","holder":"CONG TY TNHH DV VA TM QUOC TE NAM TRUNG","template":"compact2"}', 'Tài khoản nhận tiền khách (QR báo giá)'),
 ('telegram', '{"enabled":false,"chat_id":"","events":["test","leave_request","attendance_flag","quote_approval","quote_won","support","ticket","announcement","payroll","daily_summary","report_missing"]}', 'Bot Telegram báo cho BGĐ')
on conflict (key) do nothing;

insert into app.secrets(key, value) values ('telegram_bot_token', '') on conflict do nothing;

-- Tài khoản quản trị đầu tiên: đăng ký bằng đúng email này sẽ có quyền Admin + BGĐ
insert into public.invites(email, full_name, roles, job_level) values
 ('namtrung20266@gmail.com', 'Giám đốc', '{admin,bgd}', 'giam_doc'),
 ('hatrieuphong93@gmail.com', 'Giám đốc', '{admin,bgd}', 'giam_doc')
on conflict (email) do nothing;
