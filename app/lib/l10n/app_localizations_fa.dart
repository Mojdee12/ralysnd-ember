// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Persian (`fa`).
class AppLocalizationsFa extends AppLocalizations {
  AppLocalizationsFa([String locale = 'fa']) : super(locale);

  @override
  String get appTitle => 'Ralysnd Ember';

  @override
  String get navOverview => 'نمای کلی';

  @override
  String get navAccounts => 'حساب‌ها';

  @override
  String get navSettings => 'تنظیمات';

  @override
  String get stateConnected => 'متصل';

  @override
  String get stateConnecting => 'در حال اتصال…';

  @override
  String get stateWaiting => 'در انتظار';

  @override
  String get waitingForAccount =>
      'برای اتصال، در بخش حساب‌ها یک Firefox Account اضافه کنید.';

  @override
  String get waitingForEnabledAccount =>
      'همه حساب‌ها خاموش هستند. یکی را در صفحه حساب‌ها روشن کنید.';

  @override
  String get stateError => 'خطا';

  @override
  String get stateUnknown => 'نامشخص';

  @override
  String get restartProxy => 'راه‌اندازی دوباره پروکسی';

  @override
  String copied(String value) {
    return '$value کپی شد';
  }

  @override
  String get activeAccount => 'حساب فعال';

  @override
  String get noActiveAccount => 'حساب فعالی نیست';

  @override
  String get quotaNotRead => 'حجم هنوز خوانده نشده';

  @override
  String get unlimited => 'نامحدود';

  @override
  String usedOf(String used, String limit) {
    return '$used از $limit مصرف شده';
  }

  @override
  String resets(String date) {
    return 'بازنشانی در $date';
  }

  @override
  String switchAt(int percent) {
    return 'تعویض حساب در $percent٪';
  }

  @override
  String get publicIp => 'IP عمومی';

  @override
  String get testConnection => 'تست اتصال';

  @override
  String get testing => 'در حال تست…';

  @override
  String get testFailed => 'ناموفق';

  @override
  String milliseconds(int value) {
    return '$value میلی‌ثانیه';
  }

  @override
  String get justNow => 'همین الان';

  @override
  String minutesAgo(int n) {
    return '$n دقیقه پیش';
  }

  @override
  String hoursAgo(int n) {
    return '$n ساعت پیش';
  }

  @override
  String daysAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count روز پیش',
    );
    return '$_temp0';
  }

  @override
  String atTime(String time) {
    return 'ساعت $time';
  }

  @override
  String durationDays(int d, int h) {
    return '$d روز و $h ساعت';
  }

  @override
  String durationHours(int h, int m) {
    return '$h ساعت و $m دقیقه';
  }

  @override
  String durationMinutes(int m, int s) {
    return '$m دقیقه و $s ثانیه';
  }

  @override
  String durationSeconds(int s) {
    return '$s ثانیه';
  }

  @override
  String accountsGuide(String size) {
    return 'هر حساب Firefox ماهی $size حجم دارد. می‌توانید چند حساب اضافه کنید؛ وقتی حجم یکی تمام شود، برنامه خودش به حساب بعدی می‌رود.';
  }

  @override
  String accountsOrderNote(int percent) {
    return 'به ترتیب همین فهرست؛ هر حساب تا $percent٪ و آخرین حساب تا تمام شدن حجم.';
  }

  @override
  String get addAccount => 'افزودن حساب';

  @override
  String lowQuotaNotice(String left, String size) {
    return 'حجم حساب فعلی رو به اتمام است ($left مانده). با افزودن یک حساب دیگر، $size حجم دیگر خواهید داشت.';
  }

  @override
  String get noAccounts => 'هنوز حسابی نیست';

  @override
  String get noAccountsHint => 'برای اتصال یک Firefox Account اضافه کنید.';

  @override
  String get createAccountTitle => 'حساب Firefox ندارید؟';

  @override
  String get createAccountHint =>
      'در accounts.firefox.com یک حساب رایگان بسازید، بعد برگردید و «افزودن حساب» را بزنید.';

  @override
  String get moveUp => 'بالا بردن';

  @override
  String get moveDown => 'پایین بردن';

  @override
  String get statusActive => 'فعال';

  @override
  String get statusReady => 'آماده';

  @override
  String get statusNeedsSignIn => 'نیاز به ورود';

  @override
  String get statusReserved => 'رزروشده';

  @override
  String get statusUnavailable => 'در دسترس نیست';

  @override
  String statusUnavailableUntil(String date) {
    return 'تا $date در دسترس نیست';
  }

  @override
  String get statusDisabled => 'غیرفعال';

  @override
  String get statusEnabled => 'فعال';

  @override
  String get useNow => 'استفاده';

  @override
  String get signInAgain => 'ورود دوباره';

  @override
  String reasonQuotaThreshold(int percent) {
    return 'حجم این حساب به $percent٪ رسید و حساب بعدی فعال شد.';
  }

  @override
  String get reasonQuotaExhausted =>
      'حجم این ماه تمام شده؛ بعد از بازنشانی ماهانه دوباره استفاده می‌شود.';

  @override
  String get reasonSignInRequired =>
      'برای استفاده از این حساب، دوباره وارد شوید.';

  @override
  String get reasonSignInConfirm =>
      'Mozilla می‌خواهد ورود تأیید شود: «ورود دوباره» را بزنید (فقط کد لازم است).';

  @override
  String reasonSignInFailed(String detail) {
    return 'ورود خودکار ناموفق بود ($detail). دوباره وارد شوید.';
  }

  @override
  String reasonSignInWait(String time) {
    return 'ورود خودکار قبلی کمی بعد از کار افتاد؛ تلاش بعدی ساعت $time است.';
  }

  @override
  String reasonSignInRetry(String detail, String time) {
    return 'ورود خودکار کامل نشد ($detail)؛ ساعت $time دوباره تلاش می‌شود.';
  }

  @override
  String get reasonNotEntitled =>
      'Mozilla این حساب را نپذیرفت؛ بعداً دوباره تلاش می‌شود.';

  @override
  String get more => 'بیشتر';

  @override
  String get refreshQuota => 'به‌روزرسانی حجم';

  @override
  String get remove => 'حذف';

  @override
  String get removeTitle => 'حساب حذف شود؟';

  @override
  String removeBody(String name) {
    return '$name و اطلاعات ورود ذخیره‌شده آن از این کامپیوتر حذف می‌شود. بعداً می‌توانید دوباره اضافه‌اش کنید.';
  }

  @override
  String get unlimitedQuota => 'حجم نامحدود';

  @override
  String get signInTitle => 'ورود';

  @override
  String get signInIntro => 'با Firefox Account وارد شوید.';

  @override
  String get email => 'ایمیل';

  @override
  String get emailInvalid => 'ایمیل حساب را وارد کنید';

  @override
  String get password => 'رمز عبور';

  @override
  String get passwordEmpty => 'رمز عبور را وارد کنید';

  @override
  String get show => 'نمایش';

  @override
  String get hide => 'پنهان';

  @override
  String get signIn => 'ورود';

  @override
  String get continueLabel => 'ادامه';

  @override
  String get done => 'تمام';

  @override
  String get close => 'بستن';

  @override
  String get cancel => 'انصراف';

  @override
  String get tryAgain => 'تلاش دوباره';

  @override
  String get signingIn => 'در حال ورود…';

  @override
  String get accountReady => 'حساب آماده است';

  @override
  String get accountReadyHint => 'به انتهای فهرست حساب‌ها اضافه شد.';

  @override
  String get captchaLabel => 'حروف داخل تصویر';

  @override
  String get codeLabel => 'کد';

  @override
  String get captchaBroken => 'تصویر CAPTCHA نمایش داده نشد.';

  @override
  String stepEmailCode(String email) {
    return 'Mozilla یک کد به $email فرستاد. آن را اینجا وارد کنید.';
  }

  @override
  String get stepTotp => 'کد برنامه احراز هویت را وارد کنید.';

  @override
  String stepUnblockCode(String email) {
    return 'Mozilla این ورود را غیرعادی می‌داند و یک کد رفع مسدودی به $email فرستاد. آن را اینجا وارد کنید.';
  }

  @override
  String get stepCaptcha => 'حروف داخل تصویر را وارد کنید.';

  @override
  String stepEmailLink(String email) {
    return 'لینک تأییدی را که Mozilla به $email فرستاد باز کنید. ادامه کار خودکار است.';
  }

  @override
  String get signInFailed => 'حساب اضافه نشد.';

  @override
  String get signInCancelled => 'ورود لغو شد.';

  @override
  String get signInNoAccount => 'هیچ Firefox Account با این ایمیل وجود ندارد.';

  @override
  String get signInNoAccountHint =>
      'ایمیل را بررسی کنید، یا با همین ایمیل یک Firefox Account رایگان در سایت Mozilla بسازید، آن را از صندوق ایمیلتان تأیید کنید و بعد اینجا اضافه‌اش کنید.';

  @override
  String get createAccountButton => 'ساخت Firefox Account';

  @override
  String get signInWrongPassword => 'رمز عبور اشتباه است.';

  @override
  String get signInNoPassword =>
      'این حساب رمز ندارد؛ با گوگل یا اپل ساخته شده است. یک رمز بگذارید و بعد با همان رمز اینجا وارد شوید.';

  @override
  String get setPasswordButton => 'گذاشتن رمز';

  @override
  String get signInTooManyAttempts =>
      'تلاش‌ها بیش از حد بود. کمی صبر کنید و دوباره امتحان کنید.';

  @override
  String get signInUnblockRejected =>
      'کد رفع مسدودی پذیرفته نشد. کد آخرین ایمیل Mozilla را وارد کنید.';

  @override
  String get signInWrongCode =>
      'کد اشتباه است یا منقضی شده. کد آخرین ایمیل Mozilla را وارد کنید؛ با ارسال کد جدید، کد قبلی دیگر کار نمی‌کند.';

  @override
  String get signInWrongTotp =>
      'کد اشتباه است. کدی را که الان برنامه احراز هویت نشان می‌دهد وارد کنید.';

  @override
  String get signInTooManyCodes =>
      'کدهای اشتباه زیادی وارد شد. ورود را از اول شروع کنید.';

  @override
  String get signInTimedOut => 'ورود بیش از حد طول کشید. دوباره شروع کنید.';

  @override
  String get signInNetwork =>
      'به Mozilla وصل نشد. اینترنت را بررسی کنید و دوباره امتحان کنید.';

  @override
  String get coreConnecting => 'در حال اتصال به هسته…';

  @override
  String get coreLost => 'ارتباط با هسته قطع شد. در حال تلاش دوباره…';

  @override
  String get cantReachCore => 'دسترسی به هسته ممکن نیست';

  @override
  String get startingCore => 'در حال اجرای هسته…';

  @override
  String get retry => 'تلاش دوباره';

  @override
  String errNoCore(String path) {
    return 'برنامه هسته کنار اپ پیدا نشد ($path).';
  }

  @override
  String errCoreExited(String detail) {
    return 'هسته متوقف شد: $detail';
  }

  @override
  String get errNotAnswering => 'هسته پاسخ نمی‌دهد.';

  @override
  String get errRefused => 'هسته اپ را نپذیرفت؛ شاید متعلق به نسخه دیگری باشد.';

  @override
  String get settingsTitle => 'تنظیمات';

  @override
  String get sectionGeneral => 'عمومی';

  @override
  String get language => 'زبان';

  @override
  String get languageSystem => 'پیش‌فرض سیستم';

  @override
  String get theme => 'تم';

  @override
  String get themeSystem => 'سیستم';

  @override
  String get themeLight => 'روشن';

  @override
  String get themeDark => 'تیره';

  @override
  String get closeBehavior => 'هنگام بستن پنجره';

  @override
  String get closeAsk => 'هر بار بپرس';

  @override
  String get closeTray => 'پنهان شدن کنار ساعت';

  @override
  String get closeQuit => 'خروج از برنامه';

  @override
  String get sectionConnection => 'اتصال';

  @override
  String get localProxy => 'پروکسی محلی';

  @override
  String get systemProxy => 'پروکسی سیستم';

  @override
  String get sectionRouting => 'مسیریابی';

  @override
  String get routingDirect => 'اتصال مستقیم برای سایت‌های داخلی';

  @override
  String get routingDirectHint =>
      'سایت‌ها و IPهای کشور انتخاب‌شده از VPN عبور نمی‌کنند: سریع‌تر باز می‌شوند و از حجم کم نمی‌کنند.';

  @override
  String get region => 'کشور';

  @override
  String get regionIr => 'ایران';

  @override
  String get regionCn => 'چین';

  @override
  String get regionRu => 'روسیه';

  @override
  String get regionAf => 'افغانستان';

  @override
  String get regionTr => 'ترکیه';

  @override
  String get regionId => 'اندونزی';

  @override
  String get regionBr => 'برزیل';

  @override
  String get regionNone => 'هیچ‌کدام';

  @override
  String get saved => 'ذخیره شد';

  @override
  String get dataFolder => 'پوشه داده';

  @override
  String get openFolder => 'باز کردن پوشه';

  @override
  String get unofficialNote => 'کلاینت غیررسمی. وابسته به Mozilla نیست.';

  @override
  String get closeTitle => 'پنجره بسته شود؟';

  @override
  String get closeBody =>
      'وقتی برنامه کنار ساعت پنهان باشد، VPN وصل می‌ماند. با خروج، قطع می‌شود.';

  @override
  String get rememberChoice => 'انتخابم را به خاطر بسپار';

  @override
  String get minimizeToTray => 'پنهان شدن کنار ساعت';

  @override
  String get quit => 'خروج';

  @override
  String get trayOpen => 'باز کردن';

  @override
  String get trayQuit => 'خروج';

  @override
  String get trayProxyOnly => 'فقط سرویس پروکسی';

  @override
  String get traySetSystemProxy => 'تنظیم پروکسی سیستم';

  @override
  String errPortInUse(String port) {
    return 'پورت $port در اختیار برنامه دیگری است و اپ نمی‌تواند به هسته‌اش وصل شود.';
  }

  @override
  String proxyPortInUse(String port) {
    return 'پورت $port در اختیار برنامه دیگری است و پروکسی اجرا نمی‌شود.';
  }

  @override
  String get changePort => 'تغییر پورت';

  @override
  String get portDialogTitle => 'انتخاب پورت';

  @override
  String portDialogBody(String port) {
    return 'پورت $port اشغال است. یک پورت آزاد در زیر پیشنهاد شده؛ می‌توانید پورت دیگری هم وارد کنید.';
  }

  @override
  String get portChangeBody =>
      'برنامه‌ها به این پورت وصل می‌شوند. یک پورت بین 1024 تا 65535 انتخاب کنید.';

  @override
  String get portLabel => 'پورت';

  @override
  String get portInvalid => 'یک پورت بین 1024 تا 65535 وارد کنید';

  @override
  String get portBusy => 'این پورت هم اشغال است';

  @override
  String get portInUse => 'برنامه دیگری از این پورت استفاده می‌کند';

  @override
  String get save => 'ذخیره';

  @override
  String get proxyPort => 'پورت پروکسی';

  @override
  String get appPort => 'پورت اپ';

  @override
  String get welcomeTitle => 'خوش آمدید';

  @override
  String get welcomeBody =>
      'زبان و کشورتان را انتخاب کنید. سایت‌های کشورتان مستقیم و بدون VPN باز می‌شوند؛ سریع‌تر است و از حجم کم نمی‌کند.';

  @override
  String get start => 'شروع';

  @override
  String routingSuggestTitle(String country) {
    return 'مسیریابی مستقیم برای $country؟';
  }

  @override
  String routingSuggestBody(String country) {
    return 'سایت‌ها و IPهای $country مستقیم و بدون VPN باز می‌شوند. بعداً در بخش مسیریابی قابل تغییر است.';
  }

  @override
  String get yes => 'بله';

  @override
  String get notNow => 'فعلاً نه';

  @override
  String get navServers => 'سرورها';

  @override
  String get navLogs => 'لاگ‌ها';

  @override
  String get realDelay => 'تأخیر واقعی';

  @override
  String noticePort(String port) {
    return 'پروکسی Mozilla به پورت $port وصل نمی‌شود. فقط پورت‌های 80، 443، 8080 و 8443 از VPN عبور می‌کنند.';
  }

  @override
  String get noticeCommand =>
      'یک برنامه UDP خواست (بازی‌ها، تماس صوتی و تصویری). پروکسی Mozilla فقط TCP را منتقل می‌کند، پس این ترافیک عبور نمی‌کند.';

  @override
  String noticeTimes(int count, String time) {
    return '$count بار، آخرین بار $time';
  }

  @override
  String get dismiss => 'بستن';

  @override
  String get modeRecommended => 'پیشنهادی';

  @override
  String get modeFastest => 'سریع‌ترین';

  @override
  String get modeRecommendedHint => 'Mozilla مکان را برایتان انتخاب می‌کند.';

  @override
  String get modeFastestHint => 'مکانی با کمترین تأخیر در هر اتصال.';

  @override
  String get testDelay => 'تست تأخیر واقعی';

  @override
  String get testingDelay => 'در حال تست… ممکن است یک دقیقه طول بکشد';

  @override
  String get search => 'جستجو';

  @override
  String get noAnswer => 'بی‌پاسخ';

  @override
  String testedAgo(String ago) {
    return 'تست‌شده $ago';
  }

  @override
  String delaySummary(int answered, int total) {
    return '$answered از $total پاسخ دادند';
  }

  @override
  String get noServers =>
      'هنوز سروری نیست. وقتی هسته به Mozilla وصل شود، سرورها نمایش داده می‌شوند.';

  @override
  String get levelAll => 'همه';

  @override
  String get filter => 'فیلتر';

  @override
  String get follow => 'اسکرول خودکار';

  @override
  String get clear => 'پاک کردن';

  @override
  String get copyAll => 'کپی';

  @override
  String get logsCopied => 'لاگ‌ها کپی شد';

  @override
  String get noLogs => 'هنوز لاگی نیست.';

  @override
  String get sectionAccounts => 'تعویض خودکار حساب';

  @override
  String get switchThreshold => 'تعویض حساب در';

  @override
  String get switchThresholdHint =>
      'وقتی این مقدار از حجم مصرف شود، حساب بعدی جایگزین می‌شود.';

  @override
  String get sectionDns => 'DNS';

  @override
  String get dnsPreset => 'سرورهای DNS';

  @override
  String get dnsSystem => 'سیستم';

  @override
  String get dnsAuto => 'خودکار (Cloudflare، Google، Quad9)';

  @override
  String get dnsCustom => 'سفارشی';

  @override
  String get dnsCustomHint =>
      'هر خط یکی: https://…/dns-query، tls://… یا یک نشانی IP.';

  @override
  String get dnsFallback => 'استفاده از DNS سیستم اگر این‌ها پاسخ ندهند';

  @override
  String get testDns => 'تست DNS';

  @override
  String get transport => 'پروتکل';

  @override
  String get transportH3 => 'HTTP/3 (QUIC)';

  @override
  String get transportH2 => 'HTTP/2 (TCP)';

  @override
  String get directRules => 'مستقیم';

  @override
  String get directRulesHint =>
      'سایت‌ها و آدرس‌های این فهرست بدون VPN و مستقیم با اینترنت خودتان باز می‌شوند. قوانین کشوری که انتخاب کرده‌اید از قبل اینجا هست: می‌توانید خطی اضافه، ویرایش یا حذف کنید. با انتخاب کشور دیگر، قوانین آن کشور جایگزین می‌شوند.';

  @override
  String get restoreRegionRules => 'بازگرداندن قوانین کشور';

  @override
  String get blockRules => 'مسدود';

  @override
  String get blockRulesHint =>
      'سایت‌ها و آدرس‌های این فهرست اصلاً باز نمی‌شوند، نه مستقیم و نه از VPN: برای تبلیغات یا سایت‌هایی که نمی‌خواهید هیچ‌وقت باز شوند.';

  @override
  String get rulesTitle => 'قوانین';

  @override
  String get ruleSyntaxTitle => 'راهنمای نوشتن قانون';

  @override
  String get resolveDomains => 'اعمال قوانین IP روی دامنه‌ها';

  @override
  String get routingLists => 'فایل‌های Geo';

  @override
  String get listSource => 'منبع فهرست‌ها';

  @override
  String get listSourceCustom => 'تنظیم دستی';

  @override
  String listsUpdatedAgo(String ago) {
    return 'به‌روزرسانی: $ago';
  }

  @override
  String get updateLists => 'به‌روزرسانی فایل‌های Geo';

  @override
  String get listsUpdated => 'فایل‌های Geo به‌روز شدند.';

  @override
  String get testDestination => 'بررسی مسیر یک سایت';

  @override
  String get destinationHint => 'یک نام، نشانی یا URL';

  @override
  String get check => 'بررسی';

  @override
  String get routeDirect => 'مستقیم وصل می‌شود';

  @override
  String get routeProxy => 'از VPN عبور می‌کند';

  @override
  String get routeBlock => 'مسدود';

  @override
  String ruleMatched(String rule) {
    return 'قانون: $rule';
  }

  @override
  String get portRefusedNote => 'پروکسی Mozilla به این پورت وصل نمی‌شود.';

  @override
  String get sectionAdvanced => 'پیشرفته';

  @override
  String get listenAddress => 'دسترسی به پروکسی';

  @override
  String get listenLocal => '127.0.0.1 · فقط همین دستگاه';

  @override
  String get listenAll => '0.0.0.0 · همه شبکه‌ها (LAN)';

  @override
  String get proxyUsername => 'نام کاربری پروکسی';

  @override
  String get proxyPassword => 'رمز عبور پروکسی';

  @override
  String get proxyLoginHint =>
      'برنامه‌ها برای استفاده از پروکسی باید این‌ها را وارد کنند. برای استفاده بدون رمز، هر دو را خالی بگذارید.';

  @override
  String get loginBothOrNone => 'هر دو را پر کنید، یا هر دو را خالی بگذارید.';

  @override
  String get proxyLogin => 'نام کاربری و رمز پروکسی';

  @override
  String get idleSleep => 'توقف موقت هنگام عدم استفاده';

  @override
  String get sleepNever => 'هرگز';

  @override
  String sleepMinutes(int count) {
    return '$count دقیقه';
  }

  @override
  String get sleepHour => '1 ساعت';

  @override
  String get showPublicIp => 'نمایش IP عمومی';

  @override
  String get speedInNotification => 'نمایش سرعت در اعلان';

  @override
  String get liveTraffic => 'ترافیک لحظه‌ای';

  @override
  String get totalTraffic => 'ترافیک کل';

  @override
  String get verboseLogs => 'لاگ کامل';

  @override
  String get webDashboard => 'داشبورد وب';

  @override
  String get webDashboardOpen => 'باز کردن';

  @override
  String get webDashboardHint => 'تنظیمات پیشرفته و ابزارهای بیشتر';

  @override
  String numberInvalid(int min, int max) {
    return 'عددی از $min تا $max وارد کنید';
  }

  @override
  String get notifySwitchedTitle => 'حساب عوض شد';

  @override
  String notifySwitchedBody(String name) {
    return 'الان از $name استفاده می‌شود.';
  }

  @override
  String get notifySignInTitle => 'نیاز به ورود';

  @override
  String get notifySignInBody =>
      'یکی از حساب‌ها باید در صفحه حساب‌ها دوباره وارد شود.';

  @override
  String get navAbout => 'درباره';

  @override
  String get appVersionLabel => 'نسخه برنامه';

  @override
  String get coreVersionLabel => 'نسخه هسته';

  @override
  String get checkUpdates => 'بررسی به‌روزرسانی';

  @override
  String get checkingUpdates => 'در حال بررسی…';

  @override
  String get upToDate => 'آخرین نسخه را دارید.';

  @override
  String updateAvailable(String version) {
    return 'نسخه $version منتشر شده است.';
  }

  @override
  String get download => 'دانلود';

  @override
  String updateCheckFailed(String error) {
    return 'بررسی به‌روزرسانی ممکن نشد: $error';
  }

  @override
  String get updateNow => 'به‌روزرسانی';

  @override
  String updateDownloading(String version) {
    return 'در حال دانلود نسخه $version…';
  }

  @override
  String updateReady(String version) {
    return 'نسخه $version آماده نصب است.';
  }

  @override
  String updateInstalling(String version) {
    return 'در حال نصب نسخه $version؛ برنامه بسته و دوباره باز می‌شود.';
  }

  @override
  String updateFailed(String version) {
    return 'به‌روزرسانی به نسخه $version انجام نشد.';
  }

  @override
  String updateDone(String version) {
    return 'برنامه به نسخه $version به‌روز شد.';
  }

  @override
  String updateRolledBack(String version) {
    return 'به‌روزرسانی به نسخه $version کامل نشد و برنامه به نسخه قبلی برگشت.';
  }

  @override
  String get autoUpdate => 'به‌روزرسانی خودکار';

  @override
  String get autoUpdateHint =>
      'نسخه جدید در پس‌زمینه دانلود می‌شود و دفعه بعد که برنامه باز شود، نصب می‌شود.';

  @override
  String get repoNotSet => 'آدرس مخزن گیت‌هاب هنوز تنظیم نشده است.';

  @override
  String get sourceCode => 'کد منبع';

  @override
  String get tapToConnect => 'برای اتصال کلیک کنید';

  @override
  String get tapToDisconnect => 'برای قطع اتصال کلیک کنید';

  @override
  String get startOnBoot => 'اجرا با روشن شدن سیستم';

  @override
  String get connectOnStartup => 'اتصال خودکار هنگام روشن شدن';

  @override
  String get proxyServiceActive => 'سرویس پروکسی فعال';

  @override
  String get navHome => 'خانه';

  @override
  String get groupApp => 'برنامه';

  @override
  String get stateOff => 'قطع';

  @override
  String get tapToConnectPhone => 'برای اتصال ضربه بزنید';

  @override
  String get tapToDisconnectPhone => 'برای قطع اتصال ضربه بزنید';

  @override
  String lanAddress(String address) {
    return 'شبکه محلی $address';
  }

  @override
  String get recommendedLocation => 'مکان پیشنهادی';

  @override
  String dataLeftOf(String limit) {
    return 'از $limit';
  }

  @override
  String get homeLocation => 'مکان';

  @override
  String get connectedTo => 'متصل به';

  @override
  String get vpnNotAllowed =>
      'VPN به اجازه شما نیاز دارد. دوباره دکمه را بزنید و اجازه دهید.';

  @override
  String get dataUsedTitle => 'حجم مصرف‌شده';

  @override
  String get bypassApps => 'پروکسی به‌ازای هر برنامه';

  @override
  String get connectRetrying => 'اتصال برقرار نشد. اینترنت را بررسی کنید.';

  @override
  String get failUnreachable =>
      'سرورهای Mozilla روی این اینترنت فیلتر هستند. اینترنت دیگری را امتحان کنید.';

  @override
  String get failRefused =>
      'سرور Mozilla اتصال را رد کرد. چند دقیقه دیگر دوباره امتحان کنید.';

  @override
  String get failLocationRefused =>
      'این کشور برای حساب شما باز نیست. کشور دیگری انتخاب کنید.';

  @override
  String get useRecommendedLocation => 'استفاده از مکان پیشنهادی';

  @override
  String exitMismatch(String exit, String chosen) {
    return '$chosen را انتخاب کردید، اما IP شما در $exit است.';
  }

  @override
  String get failSignIn =>
      'ورود این حساب منقضی شده. از صفحه حساب‌ها دوباره وارد شوید.';

  @override
  String get failQuota => 'حجم این ماه تمام شده. حساب دیگری اضافه کنید.';

  @override
  String get failNotEntitled =>
      'این حساب از طرف Mozilla اجازه VPN ندارد. حساب دیگری اضافه کنید.';

  @override
  String get failRegion => 'سرویس Mozilla در کشور شما ارائه نمی‌شود.';

  @override
  String get failServer =>
      'سرویس Mozilla موقتاً مشکل دارد. برنامه خودش دوباره تلاش می‌کند.';

  @override
  String get failNoAccount => 'هیچ حسابی آماده نیست. صفحه حساب‌ها را باز کنید.';

  @override
  String get failTestSite =>
      'به سرور وصل شد، اما سایت‌ها باز نمی‌شوند. کشور دیگری را امتحان کنید.';

  @override
  String get failOther => 'اتصال برقرار نشد. دوباره امتحان کنید.';

  @override
  String get failNoInternet =>
      'اینترنت وصل نیست. Wi-Fi یا اینترنت موبایل را بررسی کنید.';

  @override
  String get waitingForNetwork => 'منتظر اتصال اینترنت…';

  @override
  String proxyStartFailed(String port) {
    return 'پروکسی روی پورت $port اجرا نشد. پورت دیگری انتخاب کنید.';
  }

  @override
  String get connectionSettings => 'تنظیمات اتصال';

  @override
  String get appModeExclude => 'اتصال مستقیم برنامه‌های انتخاب‌شده';

  @override
  String get appModeInclude => 'فقط برنامه‌های انتخاب‌شده از VPN';

  @override
  String get appModeExcludeHint =>
      'برنامه‌های انتخاب‌شده مستقیم وصل می‌شوند، نه از VPN؛ مثلاً اپ‌های بانکی که آدرس خارجی را نمی‌پذیرند.';

  @override
  String get appModeIncludeHint =>
      'فقط برنامه‌های انتخاب‌شده از VPN عبور می‌کنند؛ بقیه مستقیم وصل می‌شوند.';

  @override
  String fromRegionList(String region) {
    return 'پیشنهادی: در فهرست $region';
  }

  @override
  String get modeProxy => 'پروکسی';

  @override
  String get connectionMode => 'حالت اتصال';

  @override
  String get modeProxyHint =>
      'فقط برنامه‌هایی که برای پروکسی تنظیم شده‌اند از آن استفاده می‌کنند.';

  @override
  String get modeSystemProxyHint =>
      'ویندوز و بیشتر برنامه‌ها از پروکسی عبور می‌کنند.';

  @override
  String get modeSystemProxyHintOther =>
      'مرورگرها و بیشتر برنامه‌ها از پروکسی عبور می‌کنند.';

  @override
  String get suggestedApps => 'برنامه‌های پیشنهادی';

  @override
  String get showSystemApps => 'نمایش برنامه‌های سیستمی';

  @override
  String suggestedAdded(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count برنامه پیشنهادی انتخاب شد',
      zero: 'برنامه‌های پیشنهادی از قبل انتخاب شده‌اند',
    );
    return '$_temp0';
  }

  @override
  String get autoSection => 'خودکار';

  @override
  String get locationsSection => 'مکان‌ها';

  @override
  String get dnsSummaryOk => 'DNS رمزنگاری‌شده کار می‌کند';

  @override
  String dnsSummaryFailed(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count نام پیدا نشد',
    );
    return '$_temp0';
  }

  @override
  String dnsVia(String server) {
    return 'از طریق $server';
  }

  @override
  String dnsSummaryDiffers(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'DNS شبکه شما برای $count نام آدرس فیلترینگ داد. این برنامه برای آن‌ها از آن استفاده نمی‌کند.',
    );
    return '$_temp0';
  }

  @override
  String get dnsAnswer => 'پاسخ:';

  @override
  String get dnsNetworkAnswer => 'DNS شبکه:';

  @override
  String get dnsFiltered => 'فیلتر شده';

  @override
  String get rulesSyntaxTitle => 'هر خط یک قانون';

  @override
  String get ruleDomain => 'سایت و زیردامنه‌هایش';

  @override
  String get ruleFull => 'دقیقاً همین نام';

  @override
  String get ruleKeyword => 'نام‌هایی که این کلمه را دارند';

  @override
  String get ruleGeosite => 'سایت‌های یک برچسب در فایل‌های Geo';

  @override
  String get ruleGeoip => 'آدرس‌های یک کشور در فایل‌های Geo';

  @override
  String get ruleIp => 'یک آدرس یا یک شبکه';

  @override
  String get modeVpn => 'VPN';

  @override
  String get modeProxyOnly => 'فقط پروکسی';

  @override
  String get noNetwork =>
      'اتصال اینترنت برقرار نیست. اینترنت موبایل یا Wi-Fi را روشن کنید.';

  @override
  String get blockAds => 'مسدود کردن تبلیغات';

  @override
  String systemProxyTakenBy(String address) {
    return 'برنامه دیگری پروکسی سیستم را روی $address گذاشته و ترافیک از VPN نمی‌رود.';
  }

  @override
  String get systemProxyTakenOff =>
      'برنامه دیگری پروکسی سیستم را خاموش کرده و ترافیک از VPN نمی‌رود.';

  @override
  String get setSystemProxyAgain => 'دوباره تنظیم کن';

  @override
  String get modeTun => 'حالت TUN';

  @override
  String modeTunHint(String os) {
    return 'کل ترافیک $os از VPN عبور می‌کند.';
  }

  @override
  String get osWindows => 'ویندوز';

  @override
  String get osLinux => 'لینوکس';

  @override
  String get osMacos => 'مک';

  @override
  String get tunInstallWaiting => 'در انتظار اجازه برای نصب سرویس TUN…';

  @override
  String get tunInstallCancelled =>
      'حالت TUN یک بار به اجازه مدیر سیستم نیاز دارد. این اجازه داده نشد و حالت عوض نشد.';

  @override
  String tunInstallFailed(String error) {
    return 'نصب سرویس TUN ممکن نشد: $error';
  }

  @override
  String get tunStarting => 'در حال روشن کردن حالت TUN…';

  @override
  String get tunFailed => 'حالت TUN روشن نشد؛ دوباره تلاش می‌شود…';

  @override
  String get tunLost => 'حالت TUN ناگهان خاموش شد؛ دوباره تلاش می‌شود…';

  @override
  String get tunNotRunning => 'سرویس TUN اجرا نمی‌شود؛ دوباره تلاش می‌شود…';

  @override
  String get tunMissing => 'سرویس TUN نصب نیست.';

  @override
  String get tunOutdated =>
      'سرویس TUN از این برنامه قدیمی‌تر است. برای استفاده از حالت TUN دوباره نصبش کنید.';

  @override
  String get tunAppOutdated =>
      'سرویس TUN از این برنامه جدیدتر است. برای استفاده از حالت TUN برنامه را به‌روز کنید.';

  @override
  String get tunBusy => 'حالت TUN را نسخه دیگری از Firefox VPN استفاده می‌کند.';

  @override
  String get tunInstall => 'نصب';

  @override
  String get tunInstallAgain => 'نصب دوباره';

  @override
  String get trayTunMode => 'حالت TUN (همه برنامه‌ها)';

  @override
  String get removeTunService => 'حذف سرویس TUN';

  @override
  String get removeTunServiceHint =>
      'سرویس سیستمی که حالت TUN از آن استفاده می‌کند حذف می‌شود. با انتخاب دوباره حالت TUN، دوباره نصب می‌شود.';

  @override
  String get tunServiceRemoved => 'سرویس TUN حذف شد.';

  @override
  String get tunInstallPrompt =>
      'برای حالت TUN، سرویس Firefox VPN باید نصب شود.';

  @override
  String get tunRemovePrompt =>
      'برای حذف حالت TUN، سرویس Firefox VPN باید حذف شود.';

  @override
  String tunRemoveFailed(String error) {
    return 'حذف سرویس TUN ممکن نشد: $error';
  }

  @override
  String get sectionTun => 'تنظیمات TUN';

  @override
  String get tunPrograms => 'برنامه‌های بدون VPN';

  @override
  String get tunProgramsHint =>
      'مستقیم وصل می‌شوند، نه از Mozilla؛ فقط برای برنامه‌هایی که بدون VPN کار می‌کنند.';

  @override
  String get tunProgramsEmpty => 'هنوز برنامه‌ای اضافه نشده است.';

  @override
  String get addProgram => 'افزودن برنامه';

  @override
  String get programFiles => 'برنامه‌ها';

  @override
  String get tunProgramAll => 'همه ترافیک';

  @override
  String get tunProgramAllHint => 'کل برنامه مستقیم وصل می‌شود.';

  @override
  String get tunProgramUdp => 'فقط UDP';

  @override
  String get tunProgramUdpHint =>
      'فقط ترافیک UDP آن مستقیم وصل می‌شود؛ بقیه از VPN عبور می‌کند.';

  @override
  String get udpNoticeSetting => 'اعلان مسدود شدن UDP';

  @override
  String udpNoticeBody(String program) {
    return 'برنامه $program می‌خواست تماس بگیرد یا آنلاین بازی کند، ولی در حالت TUN این ترافیک (UDP) از VPN عبور نمی‌کند.';
  }

  @override
  String get udpNoticeAction => 'ترافیک UDP آن مستقیم برود';

  @override
  String get dontShowAgain => 'دیگر نشان نده';

  @override
  String udpDirectAdded(String program) {
    return 'ترافیک UDP برنامه $program از این به بعد مستقیم وصل می‌شود.';
  }

  @override
  String get addRunningProgram => 'از برنامه‌های در حال اجرا';

  @override
  String get addProgramFile => 'انتخاب فایل…';

  @override
  String get addProgramName => 'نوشتن نام…';

  @override
  String get programNameHint =>
      'نام فایل برنامه، مثل steam.exe؛ علامت * یعنی هر متنی (steam* یعنی همه برنامه‌های Steam).';

  @override
  String get runningProgramsEmpty => 'برنامه دیگری در حال اجرا نیست.';

  @override
  String get tabLog => 'لاگ';

  @override
  String get tabConnections => 'اتصال‌ها';

  @override
  String get connectionsEmpty => 'هنوز اتصالی نیست.';

  @override
  String connectionsOpen(int count) {
    return 'باز: $count';
  }

  @override
  String get connTime => 'زمان';

  @override
  String get connRoute => 'قانون';

  @override
  String get connDestination => 'مقصد';

  @override
  String get connInbound => 'ورودی';

  @override
  String get connProtocol => 'پروتکل';

  @override
  String get connColumns => 'ستون‌ها';

  @override
  String get connTraffic => 'حجم';

  @override
  String get connDuration => 'مدت';

  @override
  String get connRouteVpn => 'پروکسی';

  @override
  String get connRouteDirect => 'مستقیم';

  @override
  String get connRouteBlocked => 'مسدود';

  @override
  String get connRoutePort => 'پورت غیرمجاز';

  @override
  String get connRouteFailed => 'ناموفق';

  @override
  String get accountsTitle => 'حساب‌های من';

  @override
  String get activeBadge => 'فعال';

  @override
  String get addByPaste => 'افزودن از کلیپ‌بورد';

  @override
  String get addByQr => 'اسکن کد QR';

  @override
  String get addFirefoxAccount => 'افزودن حساب Firefox';

  @override
  String get addManual => 'افزودن دستی';

  @override
  String get addSubscription => 'افزودن اشتراک';

  @override
  String get addressRequired => 'آدرس سرور را وارد کنید.';

  @override
  String get allServers => 'همه سرورها';

  @override
  String get allSettings => 'همه تنظیمات';

  @override
  String get allowInsecure => 'اجازه اتصال ناامن (رد کردن بررسی گواهی)';

  @override
  String get autoRotation => 'چرخش خودکار';

  @override
  String get backupData => 'پشتیبان‌گیری از داده‌های V2Ray';

  @override
  String get blockDomains => 'دامنه‌های مسدود';

  @override
  String get chooseServer => 'انتخاب سرور';

  @override
  String get chooseServerSub =>
      'یا بگذارید پیشنهاد هوشمند سریع‌ترین را پیدا کند';

  @override
  String get closeAction => 'بستن';

  @override
  String get connectionSection => 'اتصال';

  @override
  String get copyLink => 'کپی لینک';

  @override
  String get coreLogs => 'گزارش‌های هسته';

  @override
  String get customRules => 'قوانین مسیریابی سفارشی';

  @override
  String daysLeft(String days) {
    return '$days روز مانده';
  }

  @override
  String get delayTest => 'تست تأخیر واقعی';

  @override
  String get deleteProfile => 'حذف کانفیگ';

  @override
  String get deleteSubscription => 'حذف اشتراک';

  @override
  String get directDomains => 'دامنه‌های مستقیم';

  @override
  String get directIps => 'آی‌پی‌های مستقیم / CIDR';

  @override
  String get dnsSection => 'DNS';

  @override
  String get doh => 'DNS رمزنگاری‌شده (DoH)';

  @override
  String get dohSub => 'جستجوی نام‌ها از روی HTTPS و داخل تونل انجام می‌شود';

  @override
  String get domainStrategy => 'راهبرد دامنه';

  @override
  String get duplicate => 'ایجاد کپی';

  @override
  String get editProfile => 'ویرایش کانفیگ';

  @override
  String get enableUdp => 'رله UDP';

  @override
  String get fakeDns => 'DNS جعلی (FakeDNS)';

  @override
  String get fieldAddress => 'آدرس';

  @override
  String get fieldCongestion => 'کنترل ازدحام';

  @override
  String get fieldDownMbps => 'دانلود (Mbps)';

  @override
  String get fieldHeaderType => 'نوع هدر';

  @override
  String get fieldKeepAlive => 'Keep-Alive پایدار';

  @override
  String get fieldLocalAddress => 'آدرس محلی (مثل 172.16.0.2/32)';

  @override
  String get fieldMethod => 'روش رمزنگاری';

  @override
  String get fieldMode => 'حالت';

  @override
  String get fieldName => 'نام';

  @override
  String get fieldNetwork => 'ترابرد';

  @override
  String get fieldObfsPassword => 'رمز مبهم‌سازی (Obfs)';

  @override
  String get fieldPassword => 'رمز عبور';

  @override
  String get fieldPath => 'مسیر';

  @override
  String get fieldPeerPublicKey => 'کلید عمومی پیر';

  @override
  String get fieldPlugin => 'پلاگین';

  @override
  String get fieldPort => 'پورت';

  @override
  String get fieldPreSharedKey => 'کلید پیش‌اشتراکی (اختیاری)';

  @override
  String get fieldProtocol => 'پروتکل';

  @override
  String get fieldPublicKey => 'کلید عمومی (pbk)';

  @override
  String get fieldReserved => 'رزرو (مثل 0,0,0)';

  @override
  String get fieldSecretKey => 'کلید خصوصی';

  @override
  String get fieldSecurity => 'امنیت';

  @override
  String get fieldSeed => 'Seed';

  @override
  String get fieldShortId => 'شناسه کوتاه (sid)';

  @override
  String get fieldUdpRelayMode => 'حالت رله UDP';

  @override
  String get fieldUpMbps => 'آپلود (Mbps)';

  @override
  String get filterAll => 'همه';

  @override
  String get fragment => 'فرگمنت TLS';

  @override
  String get fragmentSub => 'بسته اول TLS را تکه می‌کند تا از فیلتر رد شود';

  @override
  String get generalSection => 'عمومی';

  @override
  String get httpPort => 'پورت HTTP محلی';

  @override
  String get importAction => 'وارد کردن';

  @override
  String importedCount(int count) {
    return '$count کانفیگ اضافه شد';
  }

  @override
  String get ipv6Route => 'مسیر IPv6';

  @override
  String get languageRow => 'زبان';

  @override
  String get licenseNote =>
      'متن‌باز تحت GPLv3؛ بر پایه کلاینت Firefox VPN از armanlife. موتور Xray همان Xray-core (مجوز MPL-2.0) با پل tun2socks است.';

  @override
  String get linkCopied => 'لینک کپی شد';

  @override
  String get localDns => 'DNS محلی (برای رابط VPN)';

  @override
  String get looseGroup => 'کانفیگ‌های من';

  @override
  String get modeMozilla => 'موزیلا';

  @override
  String get modeV2ray => 'V2Ray';

  @override
  String get msUnit => 'میلی‌ثانیه';

  @override
  String get mux => 'مالتی‌پلکس (Mux)';

  @override
  String get muxSub =>
      'چند اتصال VLESS، VMess، Trojan و Shadowsocks را هم‌زمان روی یک تونل می‌فرستد';

  @override
  String get navSubscriptions => 'اشتراک‌ها';

  @override
  String get noAccountYet => 'هنوز حسابی نیست — برای اتصال یکی اضافه کنید';

  @override
  String get noAccountsYet => 'هنوز حسابی نیست';

  @override
  String get noProfileSelected => 'اول یک کانفیگ انتخاب کنید';

  @override
  String get noProfilesYet =>
      'هنوز کانفیگی نیست. لینک بچسبانید، کد QR اسکن کنید یا اشتراک اضافه کنید.';

  @override
  String get noServersFound => 'سروری پیدا نشد';

  @override
  String get noSubscriptionsYet => 'هنوز اشتراکی نیست';

  @override
  String get noUsageInfo => 'این اشتراک مصرفی گزارش نکرده است';

  @override
  String get nothingImported => 'چیزی وارد نشد';

  @override
  String get optimalChip => 'اتصال بهینه';

  @override
  String get pasteHint =>
      'یک یا چند لینک کانفیگ (vless، vmess، trojan، ss، wireguard، hysteria2، tuic)، یک لینک اشتراک (https://…)، یا متن کامل یک اشتراک.';

  @override
  String get perAppProxy => 'مسیریابی به‌ازای هر برنامه';

  @override
  String get pingAll => 'پینگ همه';

  @override
  String get pingLabel => 'پینگ';

  @override
  String get presetBypassIran => 'دور زدن ایران';

  @override
  String get presetBypassLan => 'دور زدن شبکه محلی';

  @override
  String get presetDirectAll => 'همه مستقیم';

  @override
  String get presetGlobal => 'سراسری';

  @override
  String profilesCount(String count) {
    return '$count کانفیگ';
  }

  @override
  String get proxyDomains => 'دامنه‌های عبوری از پروکسی';

  @override
  String get recommendedServer => 'سرور پیشنهادی';

  @override
  String get recommendedServerSub => 'پیشنهادی • کمترین پینگ';

  @override
  String remainingGb(String gb) {
    return '$gb گیگابایت باقی‌مانده';
  }

  @override
  String remainingOf(String remaining, String total) {
    return '$remaining گیگابایت باقی‌مانده از $total گیگابایت';
  }

  @override
  String get remoteDns => 'DNS راه دور';

  @override
  String get removeAccount => 'حذف حساب';

  @override
  String get restoreData => 'بازیابی داده‌های V2Ray';

  @override
  String get restoreFailed => 'آن پشتیبان بازیابی نشد';

  @override
  String get restoreOk => 'داده‌ها بازیابی شد';

  @override
  String get routingPreset => 'پیش‌تنظیم مسیریابی';

  @override
  String get saveAction => 'ذخیره';

  @override
  String get savedNote => 'ذخیره شد — از اتصال بعدی اعمال می‌شود';

  @override
  String get searchConfig => 'جستجوی کانفیگ...';

  @override
  String get searchCountry => 'جستجوی کشور...';

  @override
  String get sectionBasic => 'سرور';

  @override
  String get sectionSecurity => 'امنیت';

  @override
  String get sectionTransport => 'ترابرد';

  @override
  String get secureConnection => 'اتصال امن برقرار است';

  @override
  String get shareQr => 'نمایش کد QR';

  @override
  String get shareQrHint =>
      'این کد را در برنامه دیگری اسکن کنید تا کانفیگ وارد شود';

  @override
  String get signInNeeded => 'نیاز به ورود دوباره';

  @override
  String get smartPick => 'پیشنهاد هوشمند • سریع‌ترین سرور';

  @override
  String get smartPickSub =>
      'هسته اندازه می‌گیرد و بهترین خروجی را انتخاب می‌کند';

  @override
  String get smartRouting => 'مسیریابی هوشمند';

  @override
  String get smartRoutingSub =>
      'سایت‌های منطقه‌ای مستقیم می‌روند؛ با روشن بودنش در حجم صرفه‌جویی می‌شود';

  @override
  String get sniffing => 'اسنیفینگ';

  @override
  String get socksPort => 'پورت SOCKS محلی';

  @override
  String get sortByDelay => 'مرتب‌سازی بر اساس تأخیر';

  @override
  String get sortByName => 'مرتب‌سازی بر اساس نام';

  @override
  String get speedTest => 'تست سرعت';

  @override
  String get startFailed => 'تونل شروع نشد — گزارش‌های هسته را ببینید';

  @override
  String get statusConnected => 'متصل';

  @override
  String get statusDisconnected => 'قطع';

  @override
  String get subAdded => 'اشتراک اضافه شد';

  @override
  String get subAutoUpdate => 'به‌روزرسانی خودکار';

  @override
  String get subNameHint => 'نام (اختیاری)';

  @override
  String subUsedOf(String used, String total) {
    return '$used از $total گیگابایت استفاده شده';
  }

  @override
  String get subscriptionsTitle => 'اشتراک‌ها';

  @override
  String get tagline => 'امن • سریع • خصوصی';

  @override
  String get testAllDelays => 'تست همه';

  @override
  String get tuicNote =>
      'TUIC ذخیره و قابل اشتراک است، اما هسته Xray خروجی TUIC ندارد و فعلاً نمی‌تواند به آن وصل شود.';

  @override
  String get unsupportedProtocol => 'هسته از این پروتکل پشتیبانی نمی‌کند';

  @override
  String get updateAll => 'به‌روزرسانی همه';

  @override
  String get updateOnLaunch => 'به‌روزرسانی هنگام اجرا اگر کهنه بود';

  @override
  String usedPercent(String percent) {
    return '$percent٪ استفاده شده';
  }

  @override
  String get versionRow => 'نسخه';

  @override
  String get working => 'در حال انجام…';

  @override
  String get subUpdateFailed => 'به‌روزرسانی ناموفق بود';

  @override
  String get infoRow => 'اطلاعات';

  @override
  String get connectAction => 'اتصال';

  @override
  String get disconnectAction => 'قطع اتصال';

  @override
  String get resetStats => 'بازنشانی آمار';

  @override
  String get mapHome => 'خانه';

  @override
  String get modePsiphon => 'سایفون';

  @override
  String get psiphonRegionAuto => 'خودکار';

  @override
  String get psiphonExitRegion => 'منطقهٔ خروجی';

  @override
  String get psiphonLocalProxies => 'پروکسی‌های محلی';

  @override
  String get psiphonVpnMode => 'VPN';

  @override
  String get psiphonProxyOnly => 'فقط پروکسی';

  @override
  String get psiphonConnectionMode => 'حالت اتصال';

  @override
  String get psiphonNextConnectHint => 'تغییرات در اتصال بعدی اعمال می‌شوند.';

  @override
  String get psiphonUpstreamProxy => 'پروکسی بالادستی';

  @override
  String get psiphonUpstreamHint =>
      'سایفون اول از این پروکسی وصل می‌شود (اختیاری). یک نشانی مثل http://user:pass@host:port یا socks5://host:port.';

  @override
  String get psiphonTransports => 'ترابردها';

  @override
  String get psiphonTransportsAuto => 'خودکار';

  @override
  String get psiphonNoAccount =>
      'نیازی به حساب نیست — سایفون رایگان و ناشناس است.';

  @override
  String get psiphonLogs => 'گزارش‌های سایفون';

  @override
  String get modeLantern => 'لنترن';

  @override
  String get lanternAutoFree => 'خودکار (رایگان)';

  @override
  String get lanternFreeHint =>
      'طرح رایگان سرور را خودکار انتخاب می‌کند — در طرح رایگان انتخاب سرور وجود ندارد.';

  @override
  String get lanternNoAccount =>
      'نیازی به حساب نیست — طرح رایگان لنترن بدون ثبت‌نام کار می‌کند.';

  @override
  String get lanternLogs => 'گزارش‌های لنترن';

  @override
  String get lanternServer => 'سرور';

  @override
  String get lanternDataCap => 'حجم رایگان';

  @override
  String get lanternLocalProxy => 'پروکسی محلی';

  @override
  String get modeWarp => 'وارپ‌پلاس';

  @override
  String get warpLogs => 'گزارش‌های WARP+';

  @override
  String get warpNoAccount =>
      'نیازی به حساب نیست — warp-plus یک هویت ناشناس WARP روی همین دستگاه می‌سازد و همین‌جا نگهش می‌دارد.';

  @override
  String get warpMode => 'حالت اتصال';

  @override
  String get warpModeStandard => 'استاندارد';

  @override
  String get warpModeGool => 'WARP در WARP';

  @override
  String get warpModeCfon => 'زنجیرهٔ سایفون';

  @override
  String get warpModeStandardHint => 'یک تونل WARP، مستقیم.';

  @override
  String get warpModeGoolHint =>
      'تونل دوم WARP داخل اولی — جایی کمک می‌کند که یک اتصال WARP تنها کند یا بسته می‌شود.';

  @override
  String get warpModeCfonHint =>
      'سایفون توکارِ خود warp-plus دست‌دهی WARP را حمل می‌کند — جدا از حالت سایفون امبر.';

  @override
  String get warpScan => 'اول اسکن نقطهٔ پایانی';

  @override
  String get warpScanHint =>
      'نقاط پایانی WARP را می‌سنجد و به سریع‌ترین وصل می‌شود. شروع بیشتر طول می‌کشد.';

  @override
  String get warpCountry => 'کشور خروجی سایفون';

  @override
  String get warpEndpoint => 'نقطهٔ پایانی';

  @override
  String get warpEndpointAuto => 'خودکار';

  @override
  String get warpEndpointHint =>
      'host:port اختیاری. خالی = نقطهٔ پایانی تصادفی، یا برندهٔ اسکن.';

  @override
  String get warpNextConnectHint => 'تغییرات از اتصال بعدی اعمال می‌شوند.';

  @override
  String get warpLocalProxy => 'پروکسی محلی';

  @override
  String get warpMasqueNote =>
      'MASQUE در warp-plus v1.2.6 نیست — این موتور همیشه از پروتکل WireGuard استفاده می‌کند.';

  @override
  String get manualConfigsGroup => 'کانفیگ‌های دستی';

  @override
  String bestPingResult(String name, int ms) {
    return 'بهترین: $name · $ms ms';
  }

  @override
  String lastPingLabel(String when) {
    return 'آخرین پینگ: $when';
  }

  @override
  String get notTestedYet => 'هنوز تست نشده';

  @override
  String tabSummary(int subs, int servers) {
    return '$subs اشتراک · $servers سرور';
  }

  @override
  String get backupEmpty => 'There is nothing to back up yet';
}
