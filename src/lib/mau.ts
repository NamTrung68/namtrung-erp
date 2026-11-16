// File mẫu để nạp đúng cột (bản 24). Đọc theo TIÊU ĐỀ cột: thêm / bớt / đổi thứ tự cột khác vẫn được, chỉ cần giữ đúng tên các cột bắt buộc.
import { writeXlsx } from './xlsx';
import { TPL_BUYERS, TPL_BUYERS_GUIDE, TPL_ORDERS } from './xuathd';

/** Nháp hóa đơn APT gửi (Google Sheet / Excel). Bắt buộc: STT, MÃ KHAI BÁO, Tên hàng, Lượng, Đơn giá bán */
export const TPL_APT: any[][] = [
  ['', '', '', '', '', '', '', '', '', '', '', '', '', 'Tổng SL', '', '', '', '', '', '', 'Tổng tiền'],
  ['STT', 'Mã hàng', 'Cân', 'm3', '', '', 'Đơn hàng', 'Sale', '', '', 'MÃ KHAI BÁO', 'Mã hàng ', 'Tên hàng (mô tả chi tiết)', 'Lượng', 'ĐVT', 'Đơn giá tính thuế', 'TS NK(%)', 'TS MT', 'Đơn giá bán',
    'Thuế suất VAT(%)', 'Thành tiền', 'TIỀN VAT', 'Thành tiền thanh toán', 'NOTE', 'KT phản hồi'],
  [52, 'APT102348-22HN', 'DH5818', 'khoile', '', '', 'DH5818', 'khoile', 'MD2415', '', 'MD2415-2', 'HH10015', 'Giá đỡ cắm hoa bằng nhựa, 2 đầu vuông, KT: (7.5*7.5*16)cm, mới 100%', 1500, 'Cái', '', 0, '', 1746, 0.08, 2619000, 209520, 2828520, '', ''],
  [53, '', '', '', '', '', '', '', '', '', 'MD2415-3', 'HH10016', 'Đồ trang trí cắm hoa (cốt cắm hoa) bằng nhựa, cao 31cm, mới 100%', 760, 'Cái', '', 0, '', 5820, 0.08, 4423200, 353856, 4777056, '', ''],
  [69, 'APT102430-1HN', 'DH5814', 'trungdv22', '', '', 'DH5814', 'trungdv22', 'MD2411', '', 'MD2411-1', 'HH10039', 'Túi xách bỉm sữa (túi mẹ và bé), vải polyester, mới 100%', 110, 'Cái', '', 0, '', 94232, 0.08, 10365520, 829242, 11194762, '', ''],
];
/** File xe xuất từ hệ thống NamtrungLog. Bắt buộc: ID ĐƠN, USERNAME KHÁCH, SALE, MÃ KHAI BÁO, Tên KHAI BÁO, SỐ LƯỢNG, DVT, GIÁ TRÊN TỜ KHAI (= giá xuất khách) */
export const TPL_XE: any[][] = [
  ['NẠP KHI KÊ KHAI', '', '', '', '', 'HỆ THỐNG ĐÃ CÓ (THEO ĐƠN)'],
  ['HÌNH ẢNH HÀNG HÓA', 'THƯƠNG HIỆU', 'ID ĐƠN', 'USERNAME KHÁCH', 'SALE', 'MÃ KHAI BÁO', 'Tên KHAI BÁO KH yêu cầu', 'HS Code', 'SỐ KIỆN', 'SỐ LƯỢNG', 'DVT', 'GIÁ TRÊN TỜ KHAI',
    'MÃ VẬN ĐƠN', 'TÊN NHÀ CUNG CẤP', 'THUẾ NK', 'VAT'],
  ['', 'Không hiệu', 'MD2415', 'thuyvuvu', 'Lê Thị Minh Khơi', 'MD2415-2', 'Giá đỡ cắm hoa bằng nhựa, 2 đầu vuông', '39264000', 22, 1500, 'Cái', 1800, 's71555357079', 'WEN\'AN SHENGHAI PLASTIC', 0, 8],
  ['', 'Không hiệu', 'MD2415', 'thuyvuvu', 'Lê Thị Minh Khơi', 'MD2415-3', 'Đồ trang trí cắm hoa bằng nhựa, cao 31cm', '39264000', '', 760, 'Cái', 6000, '', '', 0, 8],
  ['', 'Không hiệu', 'MD2411', 'duongtra', 'Đỗ Văn Trung', 'MD2411-1', 'Túi xách bỉm sữa (túi mẹ và bé)', '42029290', 1, 110, 'PCE', 97000, '999641920', '', 0, 8],
];
/** HĐ chính thức APT xuất Nam Trung (sổ nhập kế toán). Bắt buộc: Mã hàng (mã MISA), Tên hàng hoá, Số lượng nhập, Đơn giá nhập, Số hóa đơn */
export const TPL_HD: any[][] = [
  ['STT', 'Mã hàng', 'Tên hàng hoá', 'Đơn vị tính', 'Thuế suất', 'Số lượng nhập', 'Đơn giá nhập', 'Thành Tiền', 'Tiền thuế vào', 'Số hóa đơn', 'Ký hiệu HĐ', 'Ngày nhập', 'Tên nhà cung cấp'],
  [2466, 'HH00044-2080-2026', 'Giá đỡ cắm hoa bằng nhựa, 2 đầu vuông, KT: (7.5*7.5*16)cm, mới 100%', 'Cái', 0.08, 1500, 1746, 2619000, 209520, 2080, 'C26TYT', '30/10/2026', 'ALPHATIC'],
  [2467, 'HH00045-2080-2026', 'Đồ trang trí cắm hoa (cốt cắm hoa) bằng nhựa, cao 31cm, mới 100%', 'Cái', 0.08, 760, 5820, 4423200, 353856, 2080, 'C26TYT', '30/10/2026', 'ALPHATIC'],
  [2478, 'HH00056-2080-2026', 'Túi xách bỉm sữa (túi mẹ và bé), vải polyester, mới 100%', 'Cái', 0.08, 110, 94232, 10365520, 829241.6, 2080, 'C26TYT', '30/10/2026', 'ALPHATIC'],
];

export type MauKind = 'apt' | 'xe' | 'hd' | 'buyers' | 'orders' | 'ton' | 'tong';
/** Bản 53: FILE TỔNG = nháp APT + file xe gộp sẵn (1 dòng = 1 dòng APT). Bắt buộc: STT, Sale, Mã khai báo, Username khách, Tên hàng, Lượng, Đơn giá bán (APT), Giá xuất khách.
 *  Nên có: Mã HS (TKN) để nhận hàng chờ hợp quy, Số lượng hệ thống để so SL, NOTE (XUẤT THẲNG / giá APT sửa). Dòng trống STT + giá APT = hàng có trên hệ thống nhưng không lên xe. */
export const TPL_TONG: any[][] = [
  ['STT', 'Mã hàng APT (kiện)', 'Đơn hàng', 'Sale', 'Mã đơn (MD)', 'Mã khai báo', 'Username khách', 'Mã hàng HH', 'Tên hàng (mô tả chi tiết)', 'Lượng', 'ĐVT', 'TS NK(%)', 'TS MT',
    'Đơn giá bán (APT)', 'Giá xuất khách', 'Mã HS (TKN)', 'Số lượng hệ thống', 'Thuế NK Khaibao', 'Thuế VAT (%)', 'Thành tiền', 'Tiền VAT', 'Thành tiền thanh toán', 'NOTE'],
  [1, 'APT102348-22HN', 'DH5818', 'khoile', 'MD2415', 'MD2415-2', 'thuyvuvu', 'HH10015', 'Giá đỡ cắm hoa bằng nhựa, 2 đầu vuông, KT: (7.5*7.5*16)cm, mới 100%', 1500, 'Cái', 0, '', 1746, 1800, '39264000', 1500, 0, 0.08, 2619000, 209520, 2828520, ''],
  [2, 'APT102348-22HN', 'DH5818', 'khoile', 'MD2415', 'MD2415-3', 'thuyvuvu', 'HH10016', 'Đồ trang trí cắm hoa (cốt cắm hoa) bằng nhựa, cao 31cm, mới 100%', 760, 'Cái', 0, '', 5820, 6000, '39264000', 760, 0, 0.08, 4423200, 353856, 4777056, ''],
  [3, 'APT102430-1HN', 'DH5814', 'trungdv22', 'MD2411', 'MD2411-1', 'duongtra', 'HH10039', 'Túi xách bỉm sữa (túi mẹ và bé), vải polyester, mới 100%', 110, 'Cái', 0, '', 94232, 97000, '42029290', 110, 0, 0.08, 10365520, 829242, 11194762, ''],
];
/** Bản 51: HĐ tồn = cột HĐ chính thức APT + Mã đơn hàng, Username, Tên sale */
export const TPL_HD_TON: any[][] = [
  [...TPL_HD[0], 'Mã đơn hàng', 'Username', 'Tên sale'],
  [...TPL_HD[1], 'MD2638', 'manhhuynh', 'Lê Thị Minh Khơi'],
  [...TPL_HD[2], 'MD2638', '', 'Lê Thị Minh Khơi'],
];
export const MAU: Record<MauKind, { name: string; file: string; rows: any[][]; sheet: string; note: string; extra?: { sheet: string; rows: any[][] }[] }> = {
  apt: { name: 'Nháp HĐ APT', file: 'Mau_1_Nhap_HD_APT', rows: TPL_APT, sheet: 'Nhap APT', note: 'Cột bắt buộc: STT, MÃ KHAI BÁO, Tên hàng, Lượng, Đơn giá bán' },
  xe: { name: 'File xe hệ thống', file: 'Mau_2_File_xe_he_thong', rows: TPL_XE, sheet: 'Khai bao', note: 'Cột bắt buộc: ID ĐƠN, USERNAME KHÁCH, SALE, MÃ KHAI BÁO, Tên KHAI BÁO, SỐ LƯỢNG, DVT, GIÁ TRÊN TỜ KHAI' },
  hd: { name: 'HĐ chính thức APT', file: 'Mau_3_HD_chinh_thuc_APT', rows: TPL_HD, sheet: 'HD APT', note: 'Cột bắt buộc: Mã hàng (HH…-số HĐ-năm), Tên hàng hoá, Số lượng nhập, Đơn giá nhập, Số hóa đơn' },
  buyers: { name: 'Pháp nhân nhận HĐ', file: 'Mau_4_Phap_nhan_nhan_HD', rows: TPL_BUYERS, sheet: 'Thong tin KH', note: '18 cột như file Xuất Excel (sheet Hướng dẫn). Ô trống = giữ nguyên, "-" = xóa trắng', extra: [{ sheet: 'Huong dan', rows: TPL_BUYERS_GUIDE }] },
  ton: { name: 'HĐ tồn', file: 'Mau_6_HD_ton', rows: TPL_HD_TON, sheet: 'HD ton', note: 'Cột HĐ chính thức APT + Mã đơn hàng, Username, Tên sale. Không có sale → không nạp; giá xuất = đơn giá nhập × 1,03' },
  tong: { name: 'File tổng xe (APT + xe)', file: 'Mau_0_File_tong_xe', rows: TPL_TONG, sheet: 'File tong', note: 'Bắt buộc: STT, Sale, Mã khai báo, Username khách, Tên hàng, Lượng, Đơn giá bán (APT), Giá xuất khách. Nên có: Mã HS (TKN), Số lượng hệ thống, NOTE' },
  orders: { name: 'Đơn hàng', file: 'Mau_5_Don_hang', rows: TPL_ORDERS, sheet: 'Don hang', note: 'Cột: Mã đơn hàng, Username, Sale, Tên hàng, Số lượng, Đơn giá xuất' },
};
export const downloadMau = (k: MauKind) => writeXlsx(MAU[k].file, MAU[k].rows, MAU[k].sheet, true, { extra: MAU[k].extra, fmt: k === 'buyers' ? { 0: 'plain', 17: 'plain' } : undefined });
