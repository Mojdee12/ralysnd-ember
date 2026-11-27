// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Vietnamese (`vi`).
class AppLocalizationsVi extends AppLocalizations {
  AppLocalizationsVi([String locale = 'vi']) : super(locale);

  @override
  String get appTitle => 'Ralysnd Ember';

  @override
  String get navOverview => 'Tổng quan';

  @override
  String get navAccounts => 'Tài khoản';

  @override
  String get navSettings => 'Cài đặt';

  @override
  String get stateConnected => 'Đã kết nối';

  @override
  String get stateConnecting => 'Đang kết nối…';

  @override
  String get stateWaiting => 'Đang chờ';

  @override
  String get waitingForAccount =>
      'Thêm một Firefox Account ở trang Tài khoản để kết nối.';

  @override
  String get waitingForEnabledAccount =>
      'Tất cả tài khoản đang tắt. Hãy bật một tài khoản ở trang Tài khoản.';

  @override
  String get stateError => 'Lỗi';

  @override
  String get stateUnknown => 'Không rõ';

  @override
  String get restartProxy => 'Khởi động lại proxy';

  @override
  String copied(String value) {
    return 'Đã sao chép $value';
  }

  @override
  String get activeAccount => 'Tài khoản đang dùng';

  @override
  String get noActiveAccount => 'Không có tài khoản đang dùng';

  @override
  String get quotaNotRead => 'Chưa có thông tin dung lượng';

  @override
  String get unlimited => 'Không giới hạn';

  @override
  String usedOf(String used, String limit) {
    return 'Đã dùng $used / $limit';
  }

  @override
  String resets(String date) {
    return 'làm mới vào $date';
  }

  @override
  String switchAt(int percent) {
    return 'Chuyển tài khoản khi đạt $percent%';
  }

  @override
  String get publicIp => 'IP công khai';

  @override
  String get testConnection => 'Kiểm tra kết nối';

  @override
  String get testing => 'Đang kiểm tra…';

  @override
  String get testFailed => 'Thất bại';

  @override
  String milliseconds(int value) {
    return '$value ms';
  }

  @override
  String get justNow => 'vừa xong';

  @override
  String minutesAgo(int n) {
    return '$n phút trước';
  }

  @override
  String hoursAgo(int n) {
    return '$n giờ trước';
  }

  @override
  String daysAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count ngày trước',
    );
    return '$_temp0';
  }

  @override
  String atTime(String time) {
    return 'lúc $time';
  }

  @override
  String durationDays(int d, int h) {
    return '$d ngày $h giờ';
  }

  @override
  String durationHours(int h, int m) {
    return '$h giờ $m phút';
  }

  @override
  String durationMinutes(int m, int s) {
    return '$m phút $s giây';
  }

  @override
  String durationSeconds(int s) {
    return '$s giây';
  }

  @override
  String accountsGuide(String size) {
    return 'Mỗi Firefox Account có $size dung lượng mỗi tháng. Bạn có thể thêm nhiều tài khoản: khi một tài khoản hết, ứng dụng tự chuyển sang tài khoản tiếp theo.';
  }

  @override
  String accountsOrderNote(int percent) {
    return 'Theo thứ tự danh sách này: mỗi tài khoản đến $percent%, tài khoản cuối dùng đến khi hết dữ liệu.';
  }

  @override
  String get addAccount => 'Thêm tài khoản';

  @override
  String lowQuotaNotice(String left, String size) {
    return 'Dung lượng của tài khoản hiện tại sắp hết (còn $left). Thêm một tài khoản nữa để có thêm $size.';
  }

  @override
  String get noAccounts => 'Chưa có tài khoản';

  @override
  String get noAccountsHint => 'Thêm một Firefox Account để kết nối.';

  @override
  String get createAccountTitle => 'Chưa có Firefox Account?';

  @override
  String get createAccountHint =>
      'Hãy tạo miễn phí tại accounts.firefox.com, rồi quay lại và nhấn Thêm tài khoản.';

  @override
  String get moveUp => 'Lên trên';

  @override
  String get moveDown => 'Xuống dưới';

  @override
  String get statusActive => 'Đang dùng';

  @override
  String get statusReady => 'Sẵn sàng';

  @override
  String get statusNeedsSignIn => 'Cần đăng nhập';

  @override
  String get statusReserved => 'Dự phòng';

  @override
  String get statusUnavailable => 'Không khả dụng';

  @override
  String statusUnavailableUntil(String date) {
    return 'Không khả dụng đến $date';
  }

  @override
  String get statusDisabled => 'Đã tắt';

  @override
  String get statusEnabled => 'Đã bật';

  @override
  String get useNow => 'Dùng ngay';

  @override
  String get signInAgain => 'Đăng nhập lại';

  @override
  String reasonQuotaThreshold(int percent) {
    return 'Tài khoản này đã dùng $percent% dữ liệu, nên tài khoản tiếp theo đã thay thế.';
  }

  @override
  String get reasonQuotaExhausted =>
      'Dung lượng tháng này đã hết; sẽ dùng lại sau khi làm mới hằng tháng.';

  @override
  String get reasonSignInRequired => 'Hãy đăng nhập lại để dùng tài khoản này.';

  @override
  String get reasonSignInConfirm =>
      'Mozilla yêu cầu xác nhận đăng nhập: nhấn Đăng nhập lại (chỉ cần mã).';

  @override
  String reasonSignInFailed(String detail) {
    return 'Đăng nhập tự động thất bại ($detail). Hãy đăng nhập lại.';
  }

  @override
  String reasonSignInWait(String time) {
    return 'Lần đăng nhập tự động gần nhất ngừng hoạt động ngay sau đó; lần thử tiếp theo lúc $time.';
  }

  @override
  String reasonSignInRetry(String detail, String time) {
    return 'Đăng nhập tự động chưa hoàn tất ($detail); sẽ thử lại lúc $time.';
  }

  @override
  String get reasonNotEntitled =>
      'Mozilla đã từ chối tài khoản này; sẽ thử lại sau.';

  @override
  String get more => 'Tùy chọn khác';

  @override
  String get refreshQuota => 'Cập nhật dung lượng';

  @override
  String get remove => 'Xóa';

  @override
  String get removeTitle => 'Xóa tài khoản?';

  @override
  String removeBody(String name) {
    return '$name và thông tin đăng nhập đã lưu sẽ bị xóa khỏi máy tính này. Bạn có thể thêm lại sau.';
  }

  @override
  String get unlimitedQuota => 'Dung lượng không giới hạn';

  @override
  String get signInTitle => 'Đăng nhập';

  @override
  String get signInIntro => 'Đăng nhập bằng Firefox Account.';

  @override
  String get email => 'Email';

  @override
  String get emailInvalid => 'Nhập email của tài khoản';

  @override
  String get password => 'Mật khẩu';

  @override
  String get passwordEmpty => 'Nhập mật khẩu';

  @override
  String get show => 'Hiện';

  @override
  String get hide => 'Ẩn';

  @override
  String get signIn => 'Đăng nhập';

  @override
  String get continueLabel => 'Tiếp tục';

  @override
  String get done => 'Xong';

  @override
  String get close => 'Đóng';

  @override
  String get cancel => 'Hủy';

  @override
  String get tryAgain => 'Thử lại';

  @override
  String get signingIn => 'Đang đăng nhập…';

  @override
  String get accountReady => 'Tài khoản đã sẵn sàng';

  @override
  String get accountReadyHint => 'Tài khoản đã được thêm vào cuối danh sách.';

  @override
  String get captchaLabel => 'Ký tự trong ảnh';

  @override
  String get codeLabel => 'Mã';

  @override
  String get captchaBroken => 'Không thể hiển thị ảnh CAPTCHA.';

  @override
  String stepEmailCode(String email) {
    return 'Mozilla đã gửi mã đến $email. Nhập mã vào đây.';
  }

  @override
  String get stepTotp => 'Nhập mã từ ứng dụng xác thực của bạn.';

  @override
  String stepUnblockCode(String email) {
    return 'Mozilla thấy lần đăng nhập này bất thường và đã gửi mã mở khóa đến $email. Nhập mã vào đây.';
  }

  @override
  String get stepCaptcha => 'Nhập các ký tự trong ảnh.';

  @override
  String stepEmailLink(String email) {
    return 'Mở liên kết xác nhận Mozilla đã gửi đến $email. Quá trình sẽ tự tiếp tục.';
  }

  @override
  String get signInFailed => 'Chưa thêm được tài khoản.';

  @override
  String get signInCancelled => 'Đã hủy đăng nhập.';

  @override
  String get signInNoAccount => 'Không có Firefox Account nào với email này.';

  @override
  String get signInNoAccountHint =>
      'Hãy kiểm tra email, hoặc tạo một Firefox Account miễn phí bằng email này trên trang của Mozilla, xác nhận từ hộp thư rồi thêm vào đây.';

  @override
  String get createAccountButton => 'Tạo Firefox Account';

  @override
  String get signInWrongPassword => 'Mật khẩu không đúng.';

  @override
  String get signInNoPassword =>
      'Tài khoản này chưa có mật khẩu: nó được tạo bằng đăng nhập Google hoặc Apple. Hãy đặt mật khẩu, rồi đăng nhập tại đây bằng mật khẩu đó.';

  @override
  String get setPasswordButton => 'Đặt mật khẩu';

  @override
  String get signInTooManyAttempts =>
      'Thử quá nhiều lần. Hãy đợi một lúc rồi thử lại.';

  @override
  String get signInUnblockRejected =>
      'Mã bỏ chặn không được chấp nhận. Hãy dùng mã trong email mới nhất của Mozilla.';

  @override
  String get signInWrongCode =>
      'Mã sai hoặc đã hết hạn. Hãy dùng mã trong email mới nhất của Mozilla; mã cũ không còn dùng được khi có mã mới.';

  @override
  String get signInWrongTotp =>
      'Mã sai. Nhập mã mà ứng dụng xác thực đang hiển thị.';

  @override
  String get signInTooManyCodes =>
      'Nhập sai mã quá nhiều lần. Hãy đăng nhập lại từ đầu.';

  @override
  String get signInTimedOut =>
      'Đăng nhập mất quá nhiều thời gian. Hãy bắt đầu lại.';

  @override
  String get signInNetwork =>
      'Không kết nối được tới Mozilla. Hãy kiểm tra internet rồi thử lại.';

  @override
  String get coreConnecting => 'Đang kết nối với lõi…';

  @override
  String get coreLost => 'Mất kết nối với lõi. Đang thử lại…';

  @override
  String get cantReachCore => 'Không kết nối được với lõi';

  @override
  String get startingCore => 'Đang khởi động lõi…';

  @override
  String get retry => 'Thử lại';

  @override
  String errNoCore(String path) {
    return 'Không tìm thấy chương trình lõi bên cạnh ứng dụng ($path).';
  }

  @override
  String errCoreExited(String detail) {
    return 'Lõi đã dừng: $detail';
  }

  @override
  String get errNotAnswering => 'Lõi không phản hồi.';

  @override
  String get errRefused =>
      'Lõi từ chối kết nối từ ứng dụng; có thể lõi này thuộc về một bản cài đặt khác.';

  @override
  String get settingsTitle => 'Cài đặt';

  @override
  String get sectionGeneral => 'Chung';

  @override
  String get language => 'Ngôn ngữ';

  @override
  String get languageSystem => 'Theo hệ thống';

  @override
  String get theme => 'Giao diện';

  @override
  String get themeSystem => 'Theo hệ thống';

  @override
  String get themeLight => 'Sáng';

  @override
  String get themeDark => 'Tối';

  @override
  String get closeBehavior => 'Khi đóng cửa sổ';

  @override
  String get closeAsk => 'Luôn hỏi';

  @override
  String get closeTray => 'Thu nhỏ xuống khay hệ thống';

  @override
  String get closeQuit => 'Thoát ứng dụng';

  @override
  String get sectionConnection => 'Kết nối';

  @override
  String get localProxy => 'Proxy cục bộ';

  @override
  String get systemProxy => 'Proxy hệ thống';

  @override
  String get sectionRouting => 'Định tuyến';

  @override
  String get routingDirect => 'Kết nối trực tiếp cho trang trong nước';

  @override
  String get routingDirectHint =>
      'Các trang và IP của quốc gia đã chọn sẽ không qua VPN: mở nhanh hơn và tiết kiệm dung lượng.';

  @override
  String get region => 'Quốc gia';

  @override
  String get regionIr => 'Iran';

  @override
  String get regionCn => 'Trung Quốc';

  @override
  String get regionRu => 'Nga';

  @override
  String get regionAf => 'Afghanistan';

  @override
  String get regionTr => 'Thổ Nhĩ Kỳ';

  @override
  String get regionId => 'Indonesia';

  @override
  String get regionBr => 'Brazil';

  @override
  String get regionNone => 'Không chọn';

  @override
  String get saved => 'Đã lưu';

  @override
  String get dataFolder => 'Thư mục dữ liệu';

  @override
  String get openFolder => 'Mở thư mục';

  @override
  String get unofficialNote =>
      'Ứng dụng không chính thức. Không liên kết với Mozilla.';

  @override
  String get closeTitle => 'Đóng cửa sổ?';

  @override
  String get closeBody =>
      'Khi thu nhỏ xuống khay hệ thống, VPN vẫn giữ kết nối. Thoát ứng dụng sẽ ngắt VPN.';

  @override
  String get rememberChoice => 'Ghi nhớ lựa chọn';

  @override
  String get minimizeToTray => 'Thu nhỏ xuống khay';

  @override
  String get quit => 'Thoát';

  @override
  String get trayOpen => 'Mở';

  @override
  String get trayQuit => 'Thoát';

  @override
  String get trayProxyOnly => 'Chỉ dịch vụ proxy';

  @override
  String get traySetSystemProxy => 'Đặt proxy hệ thống';

  @override
  String errPortInUse(String port) {
    return 'Cổng $port đang được chương trình khác sử dụng, nên ứng dụng không thể kết nối với lõi.';
  }

  @override
  String proxyPortInUse(String port) {
    return 'Cổng $port đang được chương trình khác sử dụng, nên proxy không thể khởi động.';
  }

  @override
  String get changePort => 'Đổi cổng';

  @override
  String get portDialogTitle => 'Chọn cổng';

  @override
  String portDialogBody(String port) {
    return 'Cổng $port đã bị chiếm. Một cổng trống được gợi ý bên dưới; bạn có thể nhập cổng khác.';
  }

  @override
  String get portChangeBody =>
      'Các ứng dụng kết nối tới cổng này. Hãy chọn một cổng từ 1024 đến 65535.';

  @override
  String get portLabel => 'Cổng';

  @override
  String get portInvalid => 'Nhập cổng từ 1024 đến 65535';

  @override
  String get portBusy => 'Cổng này cũng đang được dùng';

  @override
  String get portInUse => 'Một chương trình khác đang dùng cổng này';

  @override
  String get save => 'Lưu';

  @override
  String get proxyPort => 'Cổng proxy';

  @override
  String get appPort => 'Cổng ứng dụng';

  @override
  String get welcomeTitle => 'Chào mừng';

  @override
  String get welcomeBody =>
      'Chọn ngôn ngữ và quốc gia của bạn. Các trang trong nước sẽ mở trực tiếp, không qua VPN, giúp nhanh hơn và tiết kiệm dung lượng.';

  @override
  String get start => 'Bắt đầu';

  @override
  String routingSuggestTitle(String country) {
    return 'Mở trực tiếp các trang của $country?';
  }

  @override
  String routingSuggestBody(String country) {
    return 'Các trang và IP của $country sẽ mở trực tiếp, không qua VPN. Bạn có thể thay đổi trong mục Định tuyến.';
  }

  @override
  String get yes => 'Có';

  @override
  String get notNow => 'Để sau';

  @override
  String get navServers => 'Máy chủ';

  @override
  String get navLogs => 'Nhật ký';

  @override
  String get realDelay => 'Độ trễ thực';

  @override
  String noticePort(String port) {
    return 'Proxy của Mozilla không kết nối tới cổng $port. Chỉ các cổng 80, 443, 8080 và 8443 đi qua VPN.';
  }

  @override
  String get noticeCommand =>
      'Một ứng dụng yêu cầu UDP (trò chơi, gọi thoại và video). Proxy của Mozilla chỉ hỗ trợ TCP, nên lưu lượng này không thể đi qua.';

  @override
  String noticeTimes(int count, String time) {
    return '$count lần, gần nhất $time';
  }

  @override
  String get dismiss => 'Bỏ qua';

  @override
  String get modeRecommended => 'Đề xuất';

  @override
  String get modeFastest => 'Nhanh nhất';

  @override
  String get modeRecommendedHint => 'Mozilla chọn vị trí cho bạn.';

  @override
  String get modeFastestHint =>
      'Mỗi lần kết nối, chọn vị trí có độ trễ thấp nhất.';

  @override
  String get testDelay => 'Đo độ trễ thực';

  @override
  String get testingDelay => 'Đang đo… có thể mất một phút';

  @override
  String get search => 'Tìm kiếm';

  @override
  String get noAnswer => 'Không phản hồi';

  @override
  String testedAgo(String ago) {
    return 'Đã đo $ago';
  }

  @override
  String delaySummary(int answered, int total) {
    return '$answered / $total đã phản hồi';
  }

  @override
  String get noServers =>
      'Chưa có máy chủ. Danh sách sẽ hiện khi lõi kết nối được với Mozilla.';

  @override
  String get levelAll => 'Tất cả';

  @override
  String get filter => 'Lọc';

  @override
  String get follow => 'Tự động cuộn';

  @override
  String get clear => 'Xóa';

  @override
  String get copyAll => 'Sao chép';

  @override
  String get logsCopied => 'Đã sao chép nhật ký';

  @override
  String get noLogs => 'Chưa có dòng nhật ký nào.';

  @override
  String get sectionAccounts => 'Tự động chuyển tài khoản';

  @override
  String get switchThreshold => 'Chuyển tài khoản khi đạt';

  @override
  String get switchThresholdHint =>
      'Khi dung lượng đã dùng đạt mức này, ứng dụng chuyển sang tài khoản tiếp theo.';

  @override
  String get sectionDns => 'DNS';

  @override
  String get dnsPreset => 'Máy chủ DNS';

  @override
  String get dnsSystem => 'Hệ thống';

  @override
  String get dnsAuto => 'Tự động (Cloudflare, Google, Quad9)';

  @override
  String get dnsCustom => 'Tùy chỉnh';

  @override
  String get dnsCustomHint =>
      'Mỗi dòng một máy chủ: https://…/dns-query, tls://…, hoặc một địa chỉ IP.';

  @override
  String get dnsFallback => 'Dùng DNS hệ thống làm dự phòng';

  @override
  String get testDns => 'Kiểm tra DNS';

  @override
  String get transport => 'Giao thức';

  @override
  String get transportH3 => 'HTTP/3 (QUIC)';

  @override
  String get transportH2 => 'HTTP/2 (TCP)';

  @override
  String get directRules => 'Trực tiếp';

  @override
  String get directRulesHint =>
      'Các trang và địa chỉ trong danh sách này mở không qua VPN, trực tiếp bằng mạng của bạn. Quy tắc của quốc gia đã chọn đã có sẵn ở đây: bạn có thể thêm, sửa hoặc xóa dòng. Chọn quốc gia khác sẽ thay bằng quy tắc của quốc gia đó.';

  @override
  String get restoreRegionRules => 'Khôi phục quy tắc của quốc gia';

  @override
  String get blockRules => 'Chặn';

  @override
  String get blockRulesHint =>
      'Các trang và địa chỉ trong danh sách này hoàn toàn không mở được, dù trực tiếp hay qua VPN: dùng cho quảng cáo hoặc những trang bạn không bao giờ muốn truy cập.';

  @override
  String get rulesTitle => 'Quy tắc';

  @override
  String get ruleSyntaxTitle => 'Cách viết quy tắc';

  @override
  String get resolveDomains => 'Áp dụng quy tắc IP cho tên miền';

  @override
  String get routingLists => 'Tệp geo';

  @override
  String get listSource => 'Nguồn danh sách';

  @override
  String get listSourceCustom => 'Nhập thủ công';

  @override
  String listsUpdatedAgo(String ago) {
    return 'Cập nhật $ago';
  }

  @override
  String get updateLists => 'Cập nhật tệp geo';

  @override
  String get listsUpdated => 'Đã cập nhật tệp geo.';

  @override
  String get testDestination => 'Kiểm tra định tuyến';

  @override
  String get destinationHint => 'Tên miền, địa chỉ hoặc URL';

  @override
  String get check => 'Kiểm tra';

  @override
  String get routeDirect => 'Đi trực tiếp';

  @override
  String get routeProxy => 'Đi qua VPN';

  @override
  String get routeBlock => 'Bị chặn';

  @override
  String ruleMatched(String rule) {
    return 'Quy tắc: $rule';
  }

  @override
  String get portRefusedNote => 'Proxy của Mozilla không kết nối tới cổng này.';

  @override
  String get sectionAdvanced => 'Nâng cao';

  @override
  String get listenAddress => 'Quyền truy cập proxy';

  @override
  String get listenLocal => '127.0.0.1 · chỉ thiết bị này';

  @override
  String get listenAll => '0.0.0.0 · mọi mạng (LAN)';

  @override
  String get proxyUsername => 'Tên người dùng proxy';

  @override
  String get proxyPassword => 'Mật khẩu proxy';

  @override
  String get proxyLoginHint =>
      'Các ứng dụng phải dùng thông tin này để kết nối. Để trống cả hai nếu không cần xác thực.';

  @override
  String get loginBothOrNone => 'Điền cả hai, hoặc để trống cả hai.';

  @override
  String get proxyLogin => 'Xác thực proxy';

  @override
  String get idleSleep => 'Tạm dừng khi không dùng sau';

  @override
  String get sleepNever => 'Không bao giờ';

  @override
  String sleepMinutes(int count) {
    return '$count phút';
  }

  @override
  String get sleepHour => '1 giờ';

  @override
  String get showPublicIp => 'Hiện IP công khai';

  @override
  String get speedInNotification => 'Hiện tốc độ trong thông báo';

  @override
  String get liveTraffic => 'Lưu lượng hiện tại';

  @override
  String get totalTraffic => 'Tổng lưu lượng';

  @override
  String get verboseLogs => 'Nhật ký chi tiết';

  @override
  String get webDashboard => 'Bảng điều khiển web';

  @override
  String get webDashboardOpen => 'Mở';

  @override
  String get webDashboardHint => 'Cài đặt nâng cao và thêm công cụ';

  @override
  String numberInvalid(int min, int max) {
    return 'Nhập một số từ $min đến $max';
  }

  @override
  String get notifySwitchedTitle => 'Đã chuyển tài khoản';

  @override
  String notifySwitchedBody(String name) {
    return 'Đang dùng $name.';
  }

  @override
  String get notifySignInTitle => 'Cần đăng nhập';

  @override
  String get notifySignInBody =>
      'Một tài khoản cần đăng nhập lại ở trang Tài khoản.';

  @override
  String get navAbout => 'Giới thiệu';

  @override
  String get appVersionLabel => 'Phiên bản ứng dụng';

  @override
  String get coreVersionLabel => 'Phiên bản lõi';

  @override
  String get checkUpdates => 'Kiểm tra cập nhật';

  @override
  String get checkingUpdates => 'Đang kiểm tra…';

  @override
  String get upToDate => 'Bạn đang dùng phiên bản mới nhất.';

  @override
  String updateAvailable(String version) {
    return 'Đã có phiên bản mới $version.';
  }

  @override
  String get download => 'Tải xuống';

  @override
  String updateCheckFailed(String error) {
    return 'Không thể kiểm tra cập nhật: $error';
  }

  @override
  String get updateNow => 'Cập nhật';

  @override
  String updateDownloading(String version) {
    return 'Đang tải phiên bản $version…';
  }

  @override
  String updateReady(String version) {
    return 'Phiên bản $version đã sẵn sàng để cài đặt.';
  }

  @override
  String updateInstalling(String version) {
    return 'Đang cài đặt phiên bản $version. Ứng dụng sẽ đóng và mở lại.';
  }

  @override
  String updateFailed(String version) {
    return 'Không thể cập nhật lên phiên bản $version.';
  }

  @override
  String updateDone(String version) {
    return 'Đã cập nhật lên phiên bản $version.';
  }

  @override
  String updateRolledBack(String version) {
    return 'Bản cập nhật lên phiên bản $version chưa hoàn tất nên ứng dụng đã quay về phiên bản trước.';
  }

  @override
  String get autoUpdate => 'Tự động cập nhật';

  @override
  String get autoUpdateHint =>
      'Phiên bản mới được tải ở chế độ nền và được cài đặt vào lần mở ứng dụng tiếp theo.';

  @override
  String get repoNotSet => 'Chưa thiết lập kho GitHub.';

  @override
  String get sourceCode => 'Mã nguồn';

  @override
  String get tapToConnect => 'Nhấp để kết nối';

  @override
  String get tapToDisconnect => 'Nhấp để ngắt kết nối';

  @override
  String get startOnBoot => 'Khởi động cùng hệ thống';

  @override
  String get connectOnStartup => 'Tự động kết nối khi khởi động';

  @override
  String get proxyServiceActive => 'Dịch vụ proxy đang hoạt động';

  @override
  String get navHome => 'Trang chủ';

  @override
  String get groupApp => 'Ứng dụng';

  @override
  String get stateOff => 'Đã ngắt kết nối';

  @override
  String get tapToConnectPhone => 'Chạm để kết nối';

  @override
  String get tapToDisconnectPhone => 'Chạm để ngắt kết nối';

  @override
  String lanAddress(String address) {
    return 'LAN $address';
  }

  @override
  String get recommendedLocation => 'Vị trí đề xuất';

  @override
  String dataLeftOf(String limit) {
    return '/ $limit';
  }

  @override
  String get homeLocation => 'Vị trí';

  @override
  String get connectedTo => 'Đã kết nối tới';

  @override
  String get vpnNotAllowed =>
      'VPN cần sự cho phép của bạn. Chạm nút lần nữa và cho phép.';

  @override
  String get dataUsedTitle => 'Dung lượng đã dùng';

  @override
  String get bypassApps => 'Proxy theo ứng dụng';

  @override
  String get connectRetrying => 'Không thể kết nối. Hãy kiểm tra internet.';

  @override
  String get failUnreachable =>
      'Máy chủ Mozilla bị chặn trên mạng này. Hãy thử kết nối internet khác.';

  @override
  String get failRefused =>
      'Máy chủ Mozilla đã từ chối kết nối. Hãy thử lại sau vài phút.';

  @override
  String get failLocationRefused =>
      'Quốc gia này không mở cho tài khoản của bạn. Hãy chọn quốc gia khác.';

  @override
  String get useRecommendedLocation => 'Dùng vị trí đề xuất';

  @override
  String exitMismatch(String exit, String chosen) {
    return 'Bạn đã chọn $chosen, nhưng IP của bạn ở $exit.';
  }

  @override
  String get failSignIn =>
      'Phiên đăng nhập của tài khoản này đã hết hạn. Hãy đăng nhập lại ở trang Tài khoản.';

  @override
  String get failQuota =>
      'Dung lượng tháng này đã hết. Hãy thêm tài khoản khác.';

  @override
  String get failNotEntitled =>
      'Mozilla không cho tài khoản này dùng VPN. Hãy thêm tài khoản khác.';

  @override
  String get failRegion =>
      'Mozilla không cung cấp dịch vụ tại quốc gia của bạn.';

  @override
  String get failServer =>
      'Dịch vụ Mozilla đang gặp sự cố tạm thời. Ứng dụng sẽ tự thử lại.';

  @override
  String get failNoAccount =>
      'Không có tài khoản nào sẵn sàng. Hãy mở trang Tài khoản.';

  @override
  String get failTestSite =>
      'Đã kết nối máy chủ nhưng không mở được trang web. Hãy thử quốc gia khác.';

  @override
  String get failOther => 'Không thể kết nối. Hãy thử lại.';

  @override
  String get failNoInternet =>
      'Không có internet. Hãy kiểm tra Wi-Fi hoặc dữ liệu di động.';

  @override
  String get waitingForNetwork => 'Đang chờ kết nối internet…';

  @override
  String proxyStartFailed(String port) {
    return 'Không thể khởi động proxy trên cổng $port. Hãy chọn cổng khác.';
  }

  @override
  String get connectionSettings => 'Cài đặt kết nối';

  @override
  String get appModeExclude => 'Ứng dụng đã chọn không qua VPN';

  @override
  String get appModeInclude => 'Chỉ ứng dụng đã chọn qua VPN';

  @override
  String get appModeExcludeHint =>
      'Ứng dụng đã chọn kết nối trực tiếp, không qua VPN: ví dụ ứng dụng ngân hàng chặn IP nước ngoài.';

  @override
  String get appModeIncludeHint =>
      'Chỉ các ứng dụng đã chọn đi qua VPN; các ứng dụng khác kết nối trực tiếp.';

  @override
  String fromRegionList(String region) {
    return 'Gợi ý: có trong danh sách $region';
  }

  @override
  String get modeProxy => 'Proxy';

  @override
  String get connectionMode => 'Chế độ kết nối';

  @override
  String get modeProxyHint =>
      'Chỉ những ứng dụng được cài đặt dùng proxy mới đi qua proxy.';

  @override
  String get modeSystemProxyHint => 'Windows và hầu hết ứng dụng đi qua proxy.';

  @override
  String get modeSystemProxyHintOther =>
      'Trình duyệt và hầu hết ứng dụng đi qua proxy.';

  @override
  String get suggestedApps => 'Ứng dụng gợi ý';

  @override
  String get showSystemApps => 'Hiện ứng dụng hệ thống';

  @override
  String suggestedAdded(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Đã chọn $count ứng dụng gợi ý',
      one: 'Đã chọn 1 ứng dụng gợi ý',
      zero: 'Các ứng dụng gợi ý đã được chọn sẵn',
    );
    return '$_temp0';
  }

  @override
  String get autoSection => 'Tự động';

  @override
  String get locationsSection => 'Vị trí';

  @override
  String get dnsSummaryOk => 'DNS mã hóa hoạt động tốt';

  @override
  String dnsSummaryFailed(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Không phân giải được $count tên miền',
      one: 'Không phân giải được 1 tên miền',
    );
    return '$_temp0';
  }

  @override
  String dnsVia(String server) {
    return 'qua $server';
  }

  @override
  String dnsSummaryDiffers(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'DNS của mạng bạn trả về địa chỉ bị lọc cho $count tên miền. Ứng dụng không dùng DNS đó cho các tên miền này.',
      one: 'DNS của mạng bạn trả về địa chỉ bị lọc cho 1 tên miền. Ứng dụng không dùng DNS đó cho tên miền này.',
    );
    return '$_temp0';
  }

  @override
  String get dnsAnswer => 'Kết quả:';

  @override
  String get dnsNetworkAnswer => 'DNS của mạng:';

  @override
  String get dnsFiltered => 'bị lọc';

  @override
  String get rulesSyntaxTitle => 'Mỗi dòng một quy tắc';

  @override
  String get ruleDomain => 'Trang web và các tên miền con';

  @override
  String get ruleFull => 'Đúng chính xác tên miền này';

  @override
  String get ruleKeyword => 'Tên miền chứa từ khóa này';

  @override
  String get ruleGeosite => 'Các trang của một thẻ trong tệp geo';

  @override
  String get ruleGeoip => 'Các địa chỉ của một quốc gia trong tệp geo';

  @override
  String get ruleIp => 'Một địa chỉ hoặc một mạng';

  @override
  String get modeVpn => 'VPN';

  @override
  String get modeProxyOnly => 'Chỉ proxy';

  @override
  String get noNetwork =>
      'Không có kết nối internet. Hãy bật Wi-Fi hoặc dữ liệu di động.';

  @override
  String get blockAds => 'Chặn quảng cáo';

  @override
  String systemProxyTakenBy(String address) {
    return 'Một chương trình khác đã đặt proxy hệ thống thành $address, nên lưu lượng không đi qua VPN.';
  }

  @override
  String get systemProxyTakenOff =>
      'Một chương trình khác đã tắt proxy hệ thống, nên lưu lượng không đi qua VPN.';

  @override
  String get setSystemProxyAgain => 'Đặt lại';

  @override
  String get modeTun => 'TUN';

  @override
  String modeTunHint(String os) {
    return 'Toàn bộ lưu lượng của $os đi qua VPN.';
  }

  @override
  String get osWindows => 'Windows';

  @override
  String get osLinux => 'Linux';

  @override
  String get osMacos => 'macOS';

  @override
  String get tunInstallWaiting => 'Đang chờ cho phép cài đặt dịch vụ TUN…';

  @override
  String get tunInstallCancelled =>
      'Chế độ TUN cần quyền quản trị một lần. Quyền không được cấp nên chế độ không thay đổi.';

  @override
  String tunInstallFailed(String error) {
    return 'Không thể cài đặt dịch vụ TUN: $error';
  }

  @override
  String get tunStarting => 'Đang bật chế độ TUN…';

  @override
  String get tunFailed => 'Không bật được chế độ TUN. Đang thử lại…';

  @override
  String get tunLost => 'Chế độ TUN đã dừng bất ngờ. Đang thử lại…';

  @override
  String get tunNotRunning => 'Dịch vụ TUN không chạy. Đang thử lại…';

  @override
  String get tunMissing => 'Dịch vụ TUN chưa được cài đặt.';

  @override
  String get tunOutdated =>
      'Dịch vụ TUN cũ hơn ứng dụng này. Hãy cài đặt lại để dùng chế độ TUN.';

  @override
  String get tunAppOutdated =>
      'Dịch vụ TUN mới hơn ứng dụng này. Hãy cập nhật ứng dụng để dùng chế độ TUN.';

  @override
  String get tunBusy => 'Một bản Firefox VPN khác đang dùng chế độ TUN.';

  @override
  String get tunInstall => 'Cài đặt';

  @override
  String get tunInstallAgain => 'Cài đặt lại';

  @override
  String get trayTunMode => 'Chế độ TUN (mọi ứng dụng)';

  @override
  String get removeTunService => 'Gỡ dịch vụ TUN';

  @override
  String get removeTunServiceHint =>
      'Gỡ dịch vụ hệ thống mà chế độ TUN dùng. Chọn lại TUN sẽ cài đặt lại dịch vụ.';

  @override
  String get tunServiceRemoved => 'Đã gỡ dịch vụ TUN.';

  @override
  String get tunInstallPrompt =>
      'Firefox VPN muốn cài đặt dịch vụ cho chế độ TUN.';

  @override
  String get tunRemovePrompt => 'Firefox VPN muốn gỡ dịch vụ của chế độ TUN.';

  @override
  String tunRemoveFailed(String error) {
    return 'Không thể gỡ dịch vụ TUN: $error';
  }

  @override
  String get sectionTun => 'Cài đặt TUN';

  @override
  String get tunPrograms => 'Chương trình không qua VPN';

  @override
  String get tunProgramsHint =>
      'Kết nối trực tiếp, không qua Mozilla. Chỉ dành cho chương trình chạy được mà không cần VPN.';

  @override
  String get tunProgramsEmpty => 'Chưa có chương trình nào.';

  @override
  String get addProgram => 'Thêm chương trình';

  @override
  String get programFiles => 'Chương trình';

  @override
  String get tunProgramAll => 'Mọi lưu lượng';

  @override
  String get tunProgramAllHint => 'Toàn bộ chương trình kết nối trực tiếp.';

  @override
  String get tunProgramUdp => 'Chỉ UDP';

  @override
  String get tunProgramUdpHint =>
      'Chỉ UDP của nó kết nối trực tiếp; phần còn lại qua VPN.';

  @override
  String get udpNoticeSetting => 'Thông báo UDP bị chặn';

  @override
  String udpNoticeBody(String program) {
    return '$program đã cố gọi điện hoặc chơi trực tuyến, nhưng ở chế độ TUN lưu lượng này (UDP) không thể đi qua VPN.';
  }

  @override
  String get udpNoticeAction => 'Cho UDP của nó đi trực tiếp';

  @override
  String get dontShowAgain => 'Không hiện lại';

  @override
  String udpDirectAdded(String program) {
    return '$program: UDP của nó giờ kết nối trực tiếp.';
  }

  @override
  String get addRunningProgram => 'Từ các chương trình đang chạy';

  @override
  String get addProgramFile => 'Chọn tệp…';

  @override
  String get addProgramName => 'Nhập tên…';

  @override
  String get programNameHint =>
      'Tên tệp của chương trình, ví dụ steam.exe; * nghĩa là văn bản bất kỳ (steam* là mọi chương trình của Steam).';

  @override
  String get runningProgramsEmpty =>
      'Không có chương trình nào khác đang chạy.';

  @override
  String get tabLog => 'Nhật ký';

  @override
  String get tabConnections => 'Kết nối';

  @override
  String get connectionsEmpty => 'Chưa có kết nối nào.';

  @override
  String connectionsOpen(int count) {
    return '$count đang mở';
  }

  @override
  String get connTime => 'Thời gian';

  @override
  String get connRoute => 'Quy tắc';

  @override
  String get connDestination => 'Đích';

  @override
  String get connInbound => 'Đầu vào';

  @override
  String get connProtocol => 'Giao thức';

  @override
  String get connColumns => 'Cột';

  @override
  String get connTraffic => 'Lưu lượng';

  @override
  String get connDuration => 'Thời lượng';

  @override
  String get connRouteVpn => 'Proxy';

  @override
  String get connRouteDirect => 'Trực tiếp';

  @override
  String get connRouteBlocked => 'Bị chặn';

  @override
  String get connRoutePort => 'Cổng bị từ chối';

  @override
  String get connRouteFailed => 'Thất bại';

  @override
  String get accountsTitle => 'My accounts';

  @override
  String get activeBadge => 'Active';

  @override
  String get addByPaste => 'Add from clipboard';

  @override
  String get addByQr => 'Scan QR code';

  @override
  String get addFirefoxAccount => 'Add Firefox account';

  @override
  String get addManual => 'Add manually';

  @override
  String get addSubscription => 'Add subscription';

  @override
  String get addressRequired => 'Enter the server address.';

  @override
  String get allServers => 'All servers';

  @override
  String get allSettings => 'All settings';

  @override
  String get allowInsecure => 'Allow insecure (skip certificate check)';

  @override
  String get autoRotation => 'Auto-rotation';

  @override
  String get backupData => 'Back up V2Ray data';

  @override
  String get blockDomains => 'Blocked domains (direct block list)';

  @override
  String get chooseServer => 'Choose a server';

  @override
  String get chooseServerSub => 'Or let the smart pick find the fastest';

  @override
  String get closeAction => 'Close';

  @override
  String get connectionSection => 'Connection';

  @override
  String get copyLink => 'Copy link';

  @override
  String get coreLogs => 'Core logs';

  @override
  String get customRules => 'Custom routing rules';

  @override
  String daysLeft(String days) {
    return '$days days left';
  }

  @override
  String get delayTest => 'Real delay test';

  @override
  String get deleteProfile => 'Delete config';

  @override
  String get deleteSubscription => 'Delete subscription';

  @override
  String get directDomains => 'Direct domains';

  @override
  String get directIps => 'Direct IPs / CIDR';

  @override
  String get dnsSection => 'DNS';

  @override
  String get doh => 'Encrypted DNS (DoH)';

  @override
  String get dohSub => 'Name lookups go over HTTPS through the tunnel';

  @override
  String get domainStrategy => 'Domain strategy';

  @override
  String get duplicate => 'Duplicate';

  @override
  String get editProfile => 'Edit config';

  @override
  String get enableUdp => 'UDP relay';

  @override
  String get fakeDns => 'FakeDNS';

  @override
  String get fieldAddress => 'Address';

  @override
  String get fieldCongestion => 'Congestion control';

  @override
  String get fieldDownMbps => 'Downlink (Mbps)';

  @override
  String get fieldHeaderType => 'Header type';

  @override
  String get fieldKeepAlive => 'Persistent keep-alive';

  @override
  String get fieldLocalAddress => 'Local address (e.g. 172.16.0.2/32)';

  @override
  String get fieldMethod => 'Encryption method';

  @override
  String get fieldMode => 'Mode';

  @override
  String get fieldName => 'Name';

  @override
  String get fieldNetwork => 'Transport';

  @override
  String get fieldObfsPassword => 'Obfs password';

  @override
  String get fieldPassword => 'Password';

  @override
  String get fieldPath => 'Path';

  @override
  String get fieldPeerPublicKey => 'Peer public key';

  @override
  String get fieldPlugin => 'Plugin';

  @override
  String get fieldPort => 'Port';

  @override
  String get fieldPreSharedKey => 'Pre-shared key (optional)';

  @override
  String get fieldProtocol => 'Protocol';

  @override
  String get fieldPublicKey => 'Public key (pbk)';

  @override
  String get fieldReserved => 'Reserved (e.g. 0,0,0)';

  @override
  String get fieldSecretKey => 'Private key';

  @override
  String get fieldSecurity => 'Security';

  @override
  String get fieldSeed => 'Seed';

  @override
  String get fieldShortId => 'Short ID (sid)';

  @override
  String get fieldUdpRelayMode => 'UDP relay mode';

  @override
  String get fieldUpMbps => 'Uplink (Mbps)';

  @override
  String get filterAll => 'All';

  @override
  String get fragment => 'TLS fragmenting';

  @override
  String get fragmentSub => 'Splits the first TLS packet to slip past filters';

  @override
  String get generalSection => 'General';

  @override
  String get httpPort => 'Local HTTP port';

  @override
  String get importAction => 'Import';

  @override
  String importedCount(int count) {
    return '$count configs added';
  }

  @override
  String get ipv6Route => 'IPv6 route';

  @override
  String get languageRow => 'Language';

  @override
  String get licenseNote =>
      'Open source under GPLv3; based on the Firefox VPN client by armanlife. The Xray engine is Xray-core (MPL-2.0) with a tun2socks bridge.';

  @override
  String get linkCopied => 'Link copied';

  @override
  String get localDns => 'Local DNS (for the VPN interface)';

  @override
  String get looseGroup => 'My configs';

  @override
  String get modeMozilla => 'Mozilla';

  @override
  String get modeV2ray => 'V2Ray';

  @override
  String get msUnit => 'ms';

  @override
  String get mux => 'Mux';

  @override
  String get muxSub => 'Multiplexes connections over one tunnel';

  @override
  String get navSubscriptions => 'Subscriptions';

  @override
  String get noAccountYet => 'No account yet — add one to connect';

  @override
  String get noAccountsYet => 'No accounts yet';

  @override
  String get noProfileSelected => 'Choose a config first';

  @override
  String get noProfilesYet =>
      'No configs yet. Paste links, scan a QR code or add a subscription.';

  @override
  String get noServersFound => 'No servers found';

  @override
  String get noSubscriptionsYet => 'No subscriptions yet';

  @override
  String get noUsageInfo => 'No usage reported by this subscription';

  @override
  String get nothingImported => 'Nothing could be imported';

  @override
  String get optimalChip => 'Optimal';

  @override
  String get pasteHint =>
      'One or more share links (vless, vmess, trojan, ss, wireguard, hysteria2, tuic), a subscription link (https://…), or a whole subscription body.';

  @override
  String get perAppProxy => 'Per-app routing';

  @override
  String get pingAll => 'Ping all';

  @override
  String get pingLabel => 'Ping';

  @override
  String get presetBypassIran => 'Bypass Iran';

  @override
  String get presetBypassLan => 'Bypass LAN';

  @override
  String get presetDirectAll => 'All direct';

  @override
  String get presetGlobal => 'Global';

  @override
  String profilesCount(String count) {
    return '$count configs';
  }

  @override
  String get proxyDomains => 'Proxied domains';

  @override
  String get recommendedServer => 'Recommended server';

  @override
  String get recommendedServerSub => 'Recommended • lowest ping';

  @override
  String remainingGb(String gb) {
    return '$gb GB remaining';
  }

  @override
  String remainingOf(String remaining, String total) {
    return '$remaining GB remaining of $total GB';
  }

  @override
  String get remoteDns => 'Remote DNS';

  @override
  String get removeAccount => 'Remove account';

  @override
  String get restoreData => 'Restore V2Ray data';

  @override
  String get restoreFailed => 'That backup could not be restored';

  @override
  String get restoreOk => 'Data restored';

  @override
  String get routingPreset => 'Routing preset';

  @override
  String get saveAction => 'Save';

  @override
  String get savedNote => 'Saved — applies to the next connection';

  @override
  String get searchConfig => 'Search configs...';

  @override
  String get searchCountry => 'Search country...';

  @override
  String get sectionBasic => 'Server';

  @override
  String get sectionSecurity => 'Security';

  @override
  String get sectionTransport => 'Transport';

  @override
  String get secureConnection => 'Secure connection established';

  @override
  String get shareQr => 'Show QR code';

  @override
  String get shareQrHint =>
      'Scan this code in another app to import the config';

  @override
  String get signInNeeded => 'Sign-in needed';

  @override
  String get smartPick => 'Smart pick • fastest server';

  @override
  String get smartPickSub => 'The core measures and picks the best exit';

  @override
  String get smartRouting => 'Smart routing';

  @override
  String get smartRoutingSub =>
      'Regional sites go direct; when on, it saves quota';

  @override
  String get sniffing => 'Sniffing';

  @override
  String get socksPort => 'Local SOCKS port';

  @override
  String get sortByDelay => 'Sort by delay';

  @override
  String get sortByName => 'Sort by name';

  @override
  String get speedTest => 'Speed test';

  @override
  String get startFailed => 'The tunnel did not start — check the core logs';

  @override
  String get statusConnected => 'Connected';

  @override
  String get statusDisconnected => 'Disconnected';

  @override
  String get subAdded => 'Subscription added';

  @override
  String get subAutoUpdate => 'Auto-update';

  @override
  String get subNameHint => 'Name (optional)';

  @override
  String subUsedOf(String used, String total) {
    return '$used of $total GB used';
  }

  @override
  String get subscriptionsTitle => 'Subscriptions';

  @override
  String get tagline => 'Secure • Fast • Private';

  @override
  String get testAllDelays => 'Test all delays';

  @override
  String get tuicNote =>
      'TUIC is saved and can be shared, but the Xray core has no TUIC outbound, so it cannot connect yet.';

  @override
  String get unsupportedProtocol => 'Core does not support this protocol';

  @override
  String get updateAll => 'Update all';

  @override
  String get updateOnLaunch => 'Update on launch when stale';

  @override
  String usedPercent(String percent) {
    return '$percent٪ used';
  }

  @override
  String get versionRow => 'Version';

  @override
  String get working => 'Working…';

  @override
  String get subUpdateFailed => 'Update failed';

  @override
  String get infoRow => 'Info';

  @override
  String get connectAction => 'Connect';

  @override
  String get disconnectAction => 'Disconnect';

  @override
  String get resetStats => 'Reset statistics';

  @override
  String get mapHome => 'Home';

  @override
  String get modePsiphon => 'Psiphon';

  @override
  String get psiphonRegionAuto => 'Automatic';

  @override
  String get psiphonExitRegion => 'Exit region';

  @override
  String get psiphonLocalProxies => 'Local proxies';

  @override
  String get psiphonVpnMode => 'VPN';

  @override
  String get psiphonProxyOnly => 'Proxy only';

  @override
  String get psiphonConnectionMode => 'Connection mode';

  @override
  String get psiphonNextConnectHint =>
      'Changes apply the next time you connect.';

  @override
  String get psiphonUpstreamProxy => 'Upstream proxy';

  @override
  String get psiphonUpstreamHint =>
      'Psiphon connects through this proxy first (optional). A URL like http://user:pass@host:port or socks5://host:port.';

  @override
  String get psiphonTransports => 'Transports';

  @override
  String get psiphonTransportsAuto => 'Automatic';

  @override
  String get psiphonNoAccount =>
      'No account needed — Psiphon is free and anonymous.';

  @override
  String get psiphonLogs => 'Psiphon logs';

  @override
  String get modeLantern => 'Lantern';

  @override
  String get lanternAutoFree => 'Automatic (Free)';

  @override
  String get lanternFreeHint =>
      'The free plan picks the server automatically — there is no server choice on the free plan.';

  @override
  String get lanternNoAccount =>
      'No account needed — Lantern\'s free plan works without sign-up.';

  @override
  String get lanternLogs => 'Lantern logs';

  @override
  String get lanternServer => 'Server';

  @override
  String get lanternDataCap => 'Free data';

  @override
  String get lanternLocalProxy => 'Local proxy';

  @override
  String get modeWarp => 'WARP+';

  @override
  String get warpLogs => 'WARP logs';

  @override
  String get warpNoAccount =>
      'No account needed — warp-plus registers an anonymous WARP identity on this device and keeps it here.';

  @override
  String get warpMode => 'Connection mode';

  @override
  String get warpModeStandard => 'Standard';

  @override
  String get warpModeGool => 'WARP in WARP';

  @override
  String get warpModeCfon => 'Psiphon chain';

  @override
  String get warpModeStandardHint => 'One WARP tunnel, direct.';

  @override
  String get warpModeGoolHint =>
      'A second WARP tunnel inside the first — helps where a single WARP connection is throttled or blocked.';

  @override
  String get warpModeCfonHint =>
      'warp-plus\'s own built-in Psiphon carries the WARP handshake — separate from Ember\'s Psiphon mode.';

  @override
  String get warpScan => 'Scan endpoints first';

  @override
  String get warpScanHint =>
      'Probes WARP endpoints and connects to the fastest. Starting takes longer.';

  @override
  String get warpCountry => 'Psiphon exit country';

  @override
  String get warpEndpoint => 'Endpoint';

  @override
  String get warpEndpointAuto => 'Automatic';

  @override
  String get warpEndpointHint =>
      'Optional host:port. Empty = a random endpoint, or the scan\'s winner.';

  @override
  String get warpNextConnectHint => 'Changes apply on the next connect.';

  @override
  String get warpLocalProxy => 'Local proxy';

  @override
  String get warpMasqueNote =>
      'MASQUE is not in warp-plus v1.2.6 — this engine always uses the WireGuard protocol.';

  @override
  String get manualConfigsGroup => 'Manual configs';

  @override
  String bestPingResult(String name, int ms) {
    return 'Best: $name · $ms ms';
  }

  @override
  String lastPingLabel(String when) {
    return 'Last ping: $when';
  }

  @override
  String get notTestedYet => 'Not tested yet';

  @override
  String tabSummary(int subs, int servers) {
    return '$subs subscriptions · $servers servers';
  }

  @override
  String get backupEmpty => 'There is nothing to back up yet';
}
