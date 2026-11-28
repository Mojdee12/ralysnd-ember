; The Windows installer of Ralysnd Ember (Inno Setup 6). scripts\build-windows.ps1
; compiles it with the built app:
;
;   ISCC /DAppVersion=1.1.9 /DSourceDir=<the app's folder> /DOutputDir=<dir>
;        /DOutputName=<file name without .exe> firefox-vpn.iss
;
; It installs for the current user only, without administrator rights, by
; default into %LOCALAPPDATA%\Programs\Ralysnd Ember Client (apart from
; Mozilla's own client). The first install lets the user choose another
; folder; it must be one the user can write to, because the app keeps its
; data (accounts, settings, logs) in user-data beside it. A new version
; installs over the old one, in the same folder, and keeps user-data; the
; app also updates itself (core\internal\update): it replaces its files with
; a new version's and sets the version this Setup's entry in Windows' list
; of installed apps shows (AppId). An uninstall that keeps the data notes
; its folder, which the next install offers again.
;
; The TUN mode's service is the one part that needs administrator rights:
; Setup always runs core\firefox-vpn-tun.exe install, which asks for them
; itself and installs the service in Program Files; the uninstall removes it
; again.

#define AppName "Ralysnd Ember"
#define AppExe "Ralysnd Ember.exe"
#define AppDir "Ralysnd Ember"
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #error SourceDir must name the built app's folder
#endif
#ifndef OutputDir
  #define OutputDir "."
#endif
#ifndef OutputName
  #define OutputName "Ralysnd-Ember-Setup"
#endif

[Setup]
; The same id in every version, so a new one replaces the old; the app's
; own update finds this Setup's entry by it (core\internal\update).
AppId={{6F3A2C1E-9B4D-4E7A-8C21-5D0F7B9E4A63}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=Ralysnd
AppPublisherURL=https://github.com/armanlife/firefox-vpn-client
AppSupportURL=https://github.com/armanlife/firefox-vpn-client/issues
AppUpdatesURL=https://github.com/armanlife/firefox-vpn-client/releases
VersionInfoVersion={#AppVersion}
DefaultDirName={code:DefaultDir}
; The folder is asked on the first install only; an update goes where the
; installed version is.
DisableDirPage=auto
UsePreviousAppDir=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputDir}
OutputBaseFilename={#OutputName}
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
; A running copy is closed before its files are replaced.
CloseApplications=force
RestartApplications=no
ShowLanguageDialog=auto

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"
Name: "fa"; MessagesFile: "languages\Farsi.isl"
Name: "ar"; MessagesFile: "compiler:Languages\Arabic.isl"
Name: "ru"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "tr"; MessagesFile: "compiler:Languages\Turkish.isl"
Name: "az"; MessagesFile: "languages\Azerbaijan.isl"
Name: "id"; MessagesFile: "languages\Indonesian.isl"
Name: "es"; MessagesFile: "compiler:Languages\Spanish.isl"
Name: "fr"; MessagesFile: "compiler:Languages\French.isl"
Name: "hu"; MessagesFile: "compiler:Languages\Hungarian.isl"
Name: "pt"; MessagesFile: "compiler:Languages\BrazilianPortuguese.isl"
Name: "vi"; MessagesFile: "languages\Vietnamese.isl"
Name: "bn"; MessagesFile: "languages\Bengali.islu"

[CustomMessages]
; Uninstalling asks about the data, keeping it unless the user chooses
; otherwise.
DataQuestion=Keep your accounts and settings?
DataText=They stay in the user-data folder, so installing the app again brings them back. Delete them only if you will not use Ralysnd Ember again.
DataKeep=Keep them (recommended)
DataDelete=Delete them
fa.DataQuestion=حساب‌ها و تنظیمات شما نگه داشته شوند؟
fa.DataText=در پوشه user-data می‌مانند و با نصب دوباره برنامه برمی‌گردند. فقط اگر دیگر از Ralysnd Ember استفاده نمی‌کنید پاکشان کنید.
fa.DataKeep=نگه داشته شوند (پیشنهادی)
fa.DataDelete=پاک شوند
ar.DataQuestion=هل تريد الاحتفاظ بحساباتك وإعداداتك؟
ar.DataText=تبقى في مجلد user-data، فتعود عند تثبيت التطبيق مرة أخرى. احذفها فقط إذا كنت لن تستخدم Ralysnd Ember مجددًا.
ar.DataKeep=احتفظ بها (موصى به)
ar.DataDelete=احذفها
ru.DataQuestion=Сохранить ваши аккаунты и настройки?
ru.DataText=Они останутся в папке user-data, и при повторной установке приложение их вернёт. Удаляйте их, только если больше не будете пользоваться Ralysnd Ember.
ru.DataKeep=Сохранить (рекомендуется)
ru.DataDelete=Удалить
tr.DataQuestion=Hesaplarınız ve ayarlarınız saklansın mı?
tr.DataText=user-data klasöründe kalırlar; uygulamayı yeniden kurduğunuzda geri gelirler. Yalnızca Ralysnd Ember'i bir daha kullanmayacaksanız silin.
tr.DataKeep=Sakla (önerilen)
tr.DataDelete=Sil
az.DataQuestion=Hesablarınız və ayarlarınız saxlanılsın?
az.DataText=Onlar user-data qovluğunda qalır və tətbiqi yenidən quraşdıranda geri qayıdır. Yalnız Ralysnd Ember-dən bir daha istifadə etməyəcəksinizsə silin.
az.DataKeep=Saxla (tövsiyə olunur)
az.DataDelete=Sil
id.DataQuestion=Simpan akun dan pengaturan Anda?
id.DataText=Semuanya tetap di folder user-data, jadi akan kembali saat aplikasi dipasang lagi. Hapus hanya jika Anda tidak akan memakai Ralysnd Ember lagi.
id.DataKeep=Simpan (disarankan)
id.DataDelete=Hapus
es.DataQuestion=¿Conservar tus cuentas y ajustes?
es.DataText=Se quedan en la carpeta user-data, así que vuelven al instalar de nuevo la aplicación. Bórralos solo si no vas a volver a usar Ralysnd Ember.
es.DataKeep=Conservarlos (recomendado)
es.DataDelete=Borrarlos
fr.DataQuestion=Conserver vos comptes et paramètres ?
fr.DataText=Ils restent dans le dossier user-data et reviennent si vous réinstallez l'application. Ne les supprimez que si vous n'utiliserez plus Ralysnd Ember.
fr.DataKeep=Les conserver (recommandé)
fr.DataDelete=Les supprimer
hu.DataQuestion=Megtartja a fiókjait és a beállításait?
hu.DataText=A user-data mappában maradnak, így az alkalmazás újratelepítésekor visszakerülnek. Csak akkor törölje őket, ha többé nem használja a Ralysnd Ember-t.
hu.DataKeep=Megtartás (ajánlott)
hu.DataDelete=Törlés
pt.DataQuestion=Manter suas contas e configurações?
pt.DataText=Elas ficam na pasta user-data e voltam se você instalar o aplicativo de novo. Apague-as só se não for mais usar o Ralysnd Ember.
pt.DataKeep=Manter (recomendado)
pt.DataDelete=Apagar
vi.DataQuestion=Giữ lại tài khoản và cài đặt của bạn?
vi.DataText=Chúng vẫn nằm trong thư mục user-data, nên sẽ quay lại khi bạn cài lại ứng dụng. Chỉ xóa nếu bạn sẽ không dùng Ralysnd Ember nữa.
vi.DataKeep=Giữ lại (khuyên dùng)
vi.DataDelete=Xóa
bn.DataQuestion=আপনার অ্যাকাউন্ট ও সেটিংস রেখে দেবেন?
bn.DataText=এগুলো user-data ফোল্ডারে থেকে যায়, তাই অ্যাপটি আবার ইনস্টল করলে ফিরে আসে। Ralysnd Ember আর ব্যবহার না করলে তবেই মুছুন।
bn.DataKeep=রেখে দিন (প্রস্তাবিত)
bn.DataDelete=মুছে ফেলুন
; A chosen folder the user cannot write to (such as Program Files).
DirNotWritable=Ralysnd Ember can't write to this folder. It keeps your accounts and settings beside itself, so it needs a folder you can change without administrator rights (not Program Files). Choose another folder.
fa.DirNotWritable=Ralysnd Ember نمی‌تواند در این پوشه بنویسد. حساب‌ها و تنظیمات کنار خود برنامه نگه داشته می‌شوند، پس پوشه‌ای لازم است که بدون دسترسی Administrator قابل تغییر باشد (نه Program Files). پوشه دیگری انتخاب کنید.
ar.DirNotWritable=لا يستطيع Ralysnd Ember الكتابة في هذا المجلد. فهو يحتفظ بحساباتك وإعداداتك بجانبه، لذا يحتاج إلى مجلد يمكنك تعديله دون صلاحيات المسؤول (وليس Program Files). اختر مجلدًا آخر.
ru.DirNotWritable=Ralysnd Ember не может записывать в эту папку. Аккаунты и настройки хранятся рядом с программой, поэтому нужна папка, которую можно менять без прав администратора (не Program Files). Выберите другую папку.
tr.DirNotWritable=Ralysnd Ember bu klasöre yazamıyor. Hesaplarınız ve ayarlarınız uygulamanın yanında tutulur; bu yüzden yönetici hakları olmadan değiştirebileceğiniz bir klasör gerekir (Program Files değil). Başka bir klasör seçin.
az.DirNotWritable=Ralysnd Ember bu qovluğa yaza bilmir. Hesablarınız və ayarlarınız tətbiqin yanında saxlanılır, ona görə də administrator hüquqları olmadan dəyişə biləcəyiniz qovluq lazımdır (Program Files yox). Başqa qovluq seçin.
id.DirNotWritable=Ralysnd Ember tidak dapat menulis ke folder ini. Akun dan pengaturan Anda disimpan di samping aplikasi, jadi diperlukan folder yang dapat Anda ubah tanpa hak administrator (bukan Program Files). Pilih folder lain.
es.DirNotWritable=Ralysnd Ember no puede escribir en esta carpeta. Guarda tus cuentas y ajustes junto a sí mismo, así que necesita una carpeta que puedas modificar sin permisos de administrador (no Program Files). Elige otra carpeta.
fr.DirNotWritable=Ralysnd Ember ne peut pas écrire dans ce dossier. Il garde vos comptes et paramètres à côté de lui ; il lui faut donc un dossier modifiable sans droits d'administrateur (pas Program Files). Choisissez un autre dossier.
hu.DirNotWritable=A Ralysnd Ember nem tud írni ebbe a mappába. A fiókjait és a beállításait maga mellett tárolja, ezért olyan mappa kell, amelyet rendszergazdai jogok nélkül módosíthat (nem a Program Files). Válasszon másik mappát.
pt.DirNotWritable=O Ralysnd Ember não consegue gravar nesta pasta. Ele guarda suas contas e configurações ao lado de si, então precisa de uma pasta que você possa alterar sem direitos de administrador (não a Program Files). Escolha outra pasta.
vi.DirNotWritable=Ralysnd Ember không thể ghi vào thư mục này. Tài khoản và cài đặt của bạn được lưu ngay cạnh ứng dụng, nên cần một thư mục bạn có thể thay đổi mà không cần quyền quản trị (không phải Program Files). Hãy chọn thư mục khác.
bn.DirNotWritable=Ralysnd Ember এই ফোল্ডারে লিখতে পারছে না। আপনার অ্যাকাউন্ট ও সেটিংস অ্যাপের পাশেই রাখা হয়, তাই এমন একটি ফোল্ডার দরকার যা অ্যাডমিনিস্ট্রেটর অনুমতি ছাড়াই বদলানো যায় (Program Files নয়)। অন্য একটি ফোল্ডার বেছে নিন।

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

; Versions before 1.1.2 kept the core beside the app; it is in core\ now.
[InstallDelete]
Type: files; Name: "{app}\firefox-vpn-core.exe"

[Files]
; Never an existing data folder, if one was in the source.
Source: "{#SourceDir}\*"; DestDir: "{app}"; Excludes: "user-data,portable"; Flags: ignoreversion recursesubdirs createallsubdirs

; The ovpn:// / openvpn:// URL protocols (build 2157's link
; import, W2 port): a browser tap opens Ember with the link
; as the argument; the runner hands it to the running copy
; (or the first instance reads its own arguments) and the
; shell routes it to the OpenVPN importer. Per-user keys —
; the installer needs no administrator rights for them, and
; uninstalling removes them.
[Registry]
Root: HKCU; Subkey: "Software\Classes\ovpn"; ValueType: string; ValueName: ""; ValueData: "URL:OpenVPN profile link"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\ovpn"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\ovpn\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#AppExe}"" ""%1"""
Root: HKCU; Subkey: "Software\Classes\openvpn"; ValueType: string; ValueName: ""; ValueData: "URL:OpenVPN profile link"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\openvpn"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\openvpn\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#AppExe}"" ""%1"""

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
; The two services are NOT installed from here anymore (audit
; D1/D2): [Run] entries cannot inspect exit codes, so a failed
; or declined service install used to complete "successfully"
; with no service at all. They are installed from [Code]
; (InstallBundledServices, at ssPostInstall), where the exit
; code is checked and a failure aborts Setup loudly. Not in a
; silent run either way: no UAC prompt is possible there, and
; an installed service updates itself from the app.
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

; The TUN service goes with the app: through its pipe, with no prompt while
; it runs; it does nothing when the service is not installed.
[UninstallRun]
Filename: "{app}\core\firefox-vpn-tun.exe"; Parameters: "uninstall"; Flags: waituntilterminated; RunOnceId: "RemoveTunService"
Filename: "{app}\core\ember-service.exe"; Parameters: "uninstall"; Flags: waituntilterminated; RunOnceId: "RemoveEmberService"

; The app updates itself (core\internal\update) by replacing its files, so
; this uninstaller does not know every file a later version brought: the
; app's own files and folders go, whichever version put them there.
; user-data stays for the question below.
[UninstallDelete]
Type: filesandordirs; Name: "{app}\core"
Type: filesandordirs; Name: "{app}\data"
Type: filesandordirs; Name: "{app}\resources"
Type: filesandordirs; Name: "{app}\locales"
Type: filesandordirs; Name: "{app}\xray"
Type: filesandordirs; Name: "{app}\psiphon"
Type: filesandordirs; Name: "{app}\aether"
Type: filesandordirs; Name: "{app}\usque"
Type: filesandordirs; Name: "{app}\openvpn"
Type: filesandordirs; Name: "{app}\singbox"
Type: filesandordirs; Name: "{app}\wireguard"
Type: filesandordirs; Name: "{app}\lantern"
Type: filesandordirs; Name: "{app}\sudokubox"
Type: filesandordirs; Name: "{app}\zapret"
Type: filesandordirs; Name: "{app}\mieru"
Type: filesandordirs; Name: "{app}\dnscrypt"
Type: filesandordirs; Name: "{app}\dnstt"
Type: filesandordirs; Name: "{app}\wstunnel"
Type: filesandordirs; Name: "{app}\olcrtc"
Type: files; Name: "{app}\*.dll"
Type: files; Name: "{app}\*.exe"
Type: files; Name: "{app}\*.pak"
Type: files; Name: "{app}\*.bin"
Type: files; Name: "{app}\*.dat"
Type: files; Name: "{app}\LICENSE*"
Type: files; Name: "{app}\version"
Type: files; Name: "{app}\native_assets.json"

[Code]
var
  // Set by PrepareToInstall once a bundled service is confirmed
  // stopped for file replacement (audit W7): if Setup then
  // aborts, DeinitializeSetup tries to start the services again
  // instead of leaving the machine with a dead app until reboot.
  StoppedBundledServices: Boolean;
  // Set in CurStepChanged at ssDone, which fires only after a
  // successful install; its absence in DeinitializeSetup means
  // Setup aborted (or was cancelled) mid-flight.
  SetupCompletedOK: Boolean;

const
  RunKey = 'Software\Microsoft\Windows\CurrentVersion\Run';
  InternetKey = 'Software\Microsoft\Windows\CurrentVersion\Internet Settings';
  // Where an uninstall that kept the data notes the folder it is in.
  KeptKey = 'Software\{#AppName}';
  KeptValue = 'KeptDataIn';

// The folder a first install offers: the one an uninstalled copy left its
// data in, so installing again brings the data back; else the usual one.
function DefaultDir(Param: String): String;
begin
  if not RegQueryStringValue(HKCU, KeptKey, KeptValue, Result) or
     not DirExists(AddBackslash(Result) + 'user-data') then
    Result := ExpandConstant('{localappdata}\Programs\{#AppDir}');
end;

// TunServiceInstalled tells whether the TUN mode's Windows service is
// installed (core\cmd\firefox-vpn-tun).
function TunServiceInstalled: Boolean;
begin
  Result := RegKeyExists(HKLM, 'SYSTEM\CurrentControlSet\Services\FirefoxVPNTun');
end;

// IsUnder tells whether Dir is Parent or a folder inside it.
function IsUnder(Dir, Parent: String): Boolean;
begin
  Result := Pos(AddBackslash(Lowercase(Parent)), AddBackslash(Lowercase(Dir))) = 1;
end;

// CanWrite tells whether the user can create files in Dir, which the app's
// user-data needs; a folder it had to make for the test is removed again.
// Setup started as administrator can write to the system's folders, which
// the app, started normally, cannot: those are refused outright.
function CanWrite(Dir: String): Boolean;
var
  Made: Boolean;
  Probe: String;
begin
  if IsAdmin and (IsUnder(Dir, ExpandConstant('{commonpf32}')) or
     IsUnder(Dir, ExpandConstant('{commonpf64}')) or
     IsUnder(Dir, ExpandConstant('{commonappdata}')) or
     IsUnder(Dir, ExpandConstant('{win}'))) then
  begin
    Result := False;
    Exit;
  end;
  Made := not DirExists(Dir);
  Result := ForceDirectories(Dir);
  if Result then
  begin
    Probe := AddBackslash(Dir) + 'write-test.tmp';
    Result := SaveStringToFile(Probe, '', False);
    DeleteFile(Probe);
  end;
  if Made then
    RemoveDir(Dir);
end;

// A chosen folder the user cannot write to is refused before anything is
// installed (also in a silent install with /DIR).
function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if (CurPageID = wpSelectDir) and not CanWrite(WizardDirValue) then
  begin
    SuppressibleMsgBox(CustomMessage('DirNotWritable'), mbError, MB_OK, IDOK);
    Result := False;
  end;
end;

// --- Service stop before file replacement (audit D2) -------
// Before [Files] copies over {app}, both services must be
// stopped AND verified stopped: their children execute from
// {app}\xray, {app}\lantern, {app}\core..., and locked images
// mid-upgrade produced replace errors while the old service
// kept running the old build.

// ServiceStoppedOrAbsent tells whether sc.exe agrees the
// service is STOPPED, or does not exist at all (sc query exit
// code 1060 = no such service — nothing to wait for then).
function ServiceStoppedOrAbsent(Name: String): Boolean;
var
  ResultCode: Integer;
begin
  Result := False;
  if Exec(ExpandConstant('{sys}\sc.exe'), 'query "' + Name + '"', '',
     SW_HIDE, ewWaitUntilTerminated, ResultCode) and (ResultCode = 1060) then
  begin
    Result := True;
    Exit;
  end;
  // find exits 0 only when the query output says STOPPED.
  if Exec(ExpandConstant('{cmd}'), '/C sc.exe query "' + Name + '" | find "STOPPED" >nul 2>&1', '',
     SW_HIDE, ewWaitUntilTerminated, ResultCode) then
    Result := (ResultCode = 0);
end;

// StopServiceAndWait asks one service to stop, then polls the
// SCM until it is stopped or gone (up to ~30 s: the Ember
// service's children stop serially). False = still not
// stopped; the caller must not proceed over its locked files.
function StopServiceAndWait(Name: String): Boolean;
var
  ResultCode: Integer;
  Tries: Integer;
begin
  Result := ServiceStoppedOrAbsent(Name);
  if Result then
    Exit;
  Exec(ExpandConstant('{sys}\sc.exe'), 'stop "' + Name + '"', '',
    SW_HIDE, ewWaitUntilTerminated, ResultCode);
  for Tries := 0 to 59 do
  begin
    Sleep(500);
    if ServiceStoppedOrAbsent(Name) then
    begin
      Result := True;
      Exit;
    end;
  end;
  Result := False;
end;

// PrepareToInstall runs BEFORE any file is copied. Returning
// a string shows it to the user and aborts Setup — the loud
// outcome D2 asks for when a service will not stop, instead
// of copying files over a running service's locked images.
function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if StopServiceAndWait('RalysndEmberService') then
    // Confirmed stopped (or absent): remember it, so an abort
    // from here on can try to bring the services back (W7).
    StoppedBundledServices := True
  else
    Result := 'The Ralysnd Ember service did not stop, so its files cannot be replaced safely. Close Ralysnd Ember, wait a few seconds, and run Setup again.';
  if Result = '' then
  begin
    if StopServiceAndWait('FirefoxVPNTun') then
      StoppedBundledServices := True
    else
      Result := 'The Ralysnd Ember TUN service (FirefoxVPNTun) did not stop, so its files cannot be replaced safely. Close Ralysnd Ember, wait a few seconds, and run Setup again.';
  end;
end;

// --- Best-effort service restart after an abort (audit W7) --
// PrepareToInstall stopped both services before [Files]; if
// Setup then aborts, its own rollback restores FILES but
// nothing restarted the still-registered old services, leaving
// a dead app until reboot. DeinitializeSetup runs on every
// termination: when Setup did not complete successfully and we
// stopped the services, try to start them again. Strictly
// best-effort and defensive: starting an absent service fails
// harmlessly, starting a running one is refused by the SCM,
// and no error may escape DeinitializeSetup.
procedure RestartStoppedBundledServices;
var
  ResultCode: Integer;
begin
  try
    Exec(ExpandConstant('{sys}\sc.exe'), 'start "RalysndEmberService"', '',
      SW_HIDE, ewWaitUntilTerminated, ResultCode);
  except
  end;
  try
    Exec(ExpandConstant('{sys}\sc.exe'), 'start "FirefoxVPNTun"', '',
      SW_HIDE, ewWaitUntilTerminated, ResultCode);
  except
  end;
end;

procedure DeinitializeSetup;
begin
  try
    if StoppedBundledServices and not SetupCompletedOK then
      RestartStoppedBundledServices;
  except
  end;
end;

// --- Service install after files land (audit D1 visibility) -
// RunServiceInstall runs one self-elevating install verb and
// CHECKS its exit code. False (with the reason shown) when the
// verb could not even start, was declined at UAC, or exited
// non-zero.
function RunServiceInstall(FileName, LabelName: String): Boolean;
var
  ResultCode: Integer;
begin
  Result := Exec(FileName, 'install', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  if not Result then
  begin
    SuppressibleMsgBox('Setup could not start the ' + LabelName + ' installer (' + FileName + '). Ralysnd Ember will not work without it — run Setup again.', mbCriticalError, MB_OK, IDOK);
    Exit;
  end;
  if ResultCode <> 0 then
  begin
    SuppressibleMsgBox('Installing the ' + LabelName + ' failed (exit code ' + IntToStr(ResultCode) + '). This usually means the administrator prompt was declined. Ralysnd Ember will not work without it — run Setup again and approve the prompt.', mbCriticalError, MB_OK, IDOK);
    Result := False;
  end;
end;

// InstallBundledServices installs both services, TUN first
// (the order the old [Run] section used). Any failure raises:
// an exception in CurStepChanged aborts Setup with the error
// visible — never a silent "success" with no service (D1).
procedure InstallBundledServices;
begin
  if WizardSilent then
    Exit;
  if not RunServiceInstall(ExpandConstant('{app}\core\firefox-vpn-tun.exe'), 'TUN service') then
    RaiseException('The TUN service did not install; Setup is aborting instead of leaving Ralysnd Ember without it.');
  if not RunServiceInstall(ExpandConstant('{app}\core\ember-service.exe'), 'Ember service') then
    RaiseException('The Ember service did not install; Setup is aborting instead of leaving Ralysnd Ember without it.');
end;

// Installed: the services go in first (a failure aborts
// loudly, above), then the new copy's own uninstall entry
// knows its folder now.
procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
  begin
    InstallBundledServices;
    RegDeleteValue(HKCU, KeptKey, KeptValue);
    RegDeleteKeyIfEmpty(HKCU, KeptKey);
  end;
  // ssDone fires only after a successful install: it is the
  // signal DeinitializeSetup uses to tell a completed Setup
  // (services freshly installed and started — nothing to
  // restart) from an aborted one (W7 restart path).
  if CurStep = ssDone then
    SetupCompletedOK := True;
end;

// Uninstalling: the app's autostart entry goes, and so does a Windows
// proxy setting the app left pointing at its own (now gone) proxy; then
// the data, if the user wants. Kept data's folder is noted for the next
// install.
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Enabled: Cardinal;
  Server: String;
  Data: String;
begin
  if CurUninstallStep = usUninstall then
  begin
    RegDeleteValue(HKCU, RunKey, '{#AppName}');
    if RegQueryDWordValue(HKCU, InternetKey, 'ProxyEnable', Enabled) and (Enabled = 1) and
       RegQueryStringValue(HKCU, InternetKey, 'ProxyServer', Server) and
       (Pos('127.0.0.1:', Server) = 1) then
      RegWriteDWordValue(HKCU, InternetKey, 'ProxyEnable', 0);
  end;
  if CurUninstallStep = usPostUninstall then
  begin
    Data := ExpandConstant('{app}\user-data');
    // Keep is the first and default button; a silent uninstall keeps too.
    if DirExists(Data) and not UninstallSilent and
       (TaskDialogMsgBox(CustomMessage('DataQuestion'), CustomMessage('DataText'), mbConfirmation,
          MB_YESNO, [CustomMessage('DataKeep'), CustomMessage('DataDelete')], 0) = IDNO) then
      DelTree(Data, True, True, True);
    if DirExists(Data) then
      RegWriteStringValue(HKCU, KeptKey, KeptValue, ExpandConstant('{app}'))
    else
    begin
      RegDeleteValue(HKCU, KeptKey, KeptValue);
      RegDeleteKeyIfEmpty(HKCU, KeptKey);
    end;
    RemoveDir(ExpandConstant('{app}'));
  end;
end;
