unit mysql_daemon;

{$MODE DELPHI}
{$LONGSTRINGS ON}

interface

uses
    Classes, SysUtils,variants,strutils,IniFiles, Process,logs,unix,RegExpr in 'RegExpr.pas',zsystem,openldap;

type LDAP=record
      admin:string;
      password:string;
      suffix:string;
      servername:string;
      Port:string;
  end;

  type
  tmysql_daemon=class


private
     LOGS:Tlogs;
     D:boolean;
     SYS:Tsystem;
     artica_path:string;
     EnableMysqlClusterManager:integer;
     EnableMysqlClusterReplicat:integer;
     innodb_file_per_table:integer;
     EnableMysqlLog:integer;
     thread_concurrency:integer;
     procedure CleanIniMysql();
     procedure cluster_management_saveconf();
     procedure cluster_replicat_saveconf();
     function PID_CLUSTER():string;
     function PID_CLUSTER_REPLICAT():string;
     procedure DELETE_PARAMETERS(key:string);
     function checks_errors():boolean;

public
    procedure   Free;
    constructor Create(const zSYS:Tsystem);
    function    VERSION():string;
    procedure   SERVICE_START(nochecks:boolean=false);
    procedure   SERVICE_STOP();
    FUNCTION    STATUS():string;
    function    CNF_PATH():string;
    function    INIT_PATH():string;
    function    PID_PATH():string;
    function    SERVER_PARAMETERS(key:string):string;
    function    SERVER_DEFAULTS(key:string):string;
    function    PID_NUM():string;
    function    daemon_bin_path():string;
    function    mysqld_safe_path():string;
    procedure   SET_MYSQLD_PARAMETERS(key:string;value:string);
    procedure   SET_PARAMETERS(bigkey:string;key:string;value:string);
    procedure   DELETE_MYSQLD_PARAMETERS(bikeykey:string;key:string);
    procedure   CHANGE_ROOT_PASSWORD(password:string);
    FUNCTION    CHECK_ERRORS_INFILE(path:string):boolean;
    procedure   CLUSTER_MANAGEMENT_START();
    procedure   CLUSTER_REPLICA_START();
    procedure   CLUSTER_MANAGEMENT_STOP();
    procedure   CLUSTER_REPLICA_STOP();
    procedure   REPAIR_DATABASES();
    procedure   CleanMyCnf();
    procedure   TUNE_MYSQL();
    procedure   CHANGE_MYSQL_ROOT();
    function    MON():string;
    procedure   SSL_KEY();
END;

implementation

constructor tmysql_daemon.Create(const zSYS:Tsystem);
begin
       forcedirectories('/etc/artica-postfix');
       LOGS:=tlogs.Create();
       SYS:=zSYS;
       D:=LOGS.COMMANDLINE_PARAMETERS('debug');
       EnableMysqlClusterManager:=0;

       if not tryStrToInt(SYS.GET_INFO('EnableMysqlClusterManager'),EnableMysqlClusterManager) then EnableMysqlClusterManager:=0;
       if not tryStrToInt(SYS.GET_INFO('EnableMysqlClusterReplicat'),EnableMysqlClusterReplicat) then EnableMysqlClusterReplicat:=0;
       if not tryStrToInt(SYS.GET_INFO('EnableMysqlLog'),EnableMysqlLog) then EnableMysqlLog:=0;
       if not tryStrToInt(SYS.GET_INFO('innodb_file_per_table'),innodb_file_per_table) then innodb_file_per_table:=0;

       thread_concurrency:=SYS.CPU_NUMBER()*2;
       if EnableMysqlClusterManager=1 then EnableMysqlClusterReplicat:=0;

       if D then logs.Debuglogs('tobm.Create():: debug=true');
       if not DirectoryExists('/usr/share/artica-postfix') then begin
              artica_path:=ParamStr(0);
              artica_path:=ExtractFilePath(artica_path);
              artica_path:=AnsiReplaceText(artica_path,'/bin/','');

      end else begin
          artica_path:='/usr/share/artica-postfix';
      end;
end;
//##############################################################################
procedure tmysql_daemon.free();
begin
    logs.Free;
end;
//##############################################################################
function tmysql_daemon.PID_PATH():string;
var
   pidpath:string;
begin
     pidpath:=SERVER_PARAMETERS('pid-file');
     result:=pidpath;
end;
//##############################################################################
function tmysql_daemon.PID_NUM():string;
begin
     result:=trim(SYS.GET_PID_FROM_PATH(PID_PATH()));
     if not FileExists('/proc/'+result+'/exe') then begin
         result:=SYS.PidByProcessPath(daemon_bin_path());
     end;
end;
//##############################################################################
function tmysql_daemon.CNF_PATH():string;
begin
  if FileExists('/etc/mysql/my.cnf') then exit('/etc/mysql/my.cnf');
  if FileExists('/etc/my.cnf') then exit('/etc/my.cnf');
  exit('/etc/mysql/my.cnf');
end;
//#############################################################################
function tmysql_daemon.daemon_bin_path():string;
begin
  exit(SYS.LOCATE_mysqld_bin());
end;
//#############################################################################

function tmysql_daemon.INIT_PATH():string;
begin
  if FileExists('/etc/init.d/mysql') then exit('/etc/init.d/mysql');
  if FileExists('/etc/init.d/mysqld') then exit('/etc/init.d/mysqld');
  if FileExists('/etc/rc.d/mysqld') then exit('/etc/rc.d/mysqld');
end;
//#############################################################################
function tmysql_daemon.mysqld_safe_path():string;
begin
  if FileExists('/usr/bin/mysqld_safe') then exit('/usr/bin/mysqld_safe');
end;
//#############################################################################
procedure tmysql_daemon.SET_MYSQLD_PARAMETERS(key:string;value:string);
var Ini:TiniFile;
begin

  if not FileExists(CNF_PATH()) then exit();
  ini:=TiniFile.Create(CNF_PATH());
  ini.WriteString('mysqld',key,value);
  ini.UpdateFile;
  ini.free;
end;
//#############################################################################
procedure tmysql_daemon.DELETE_MYSQLD_PARAMETERS(bikeykey:string;key:string);
var
 RegExpr:TRegExpr;
 l:tstringlist;
 start:boolean;
 found:boolean;
 i:integer;
begin

  if not FileExists(CNF_PATH()) then begin
     logs.DebugLogs('Starting......: Unable to stat my.cnf (DELETE_MYSQLD_PARAMETERS)');
     exit();
  end;
  start:=false;
  found:=false;
  l:=Tstringlist.Create;
  l.LoadFromFile(CNF_PATH());
  RegExpr:=TRegExpr.Create;
  for i:=0 to l.Count-1 do begin
      RegExpr.Expression:='\['+bikeykey+'\]';
      if RegExpr.Exec(l.Strings[i]) then begin
         start:=true;
         continue;
      end;

      if start then begin
            RegExpr.Expression:='\[';
            if RegExpr.Exec(l.Strings[i]) then break;
            RegExpr.Expression:=key;
            if RegExpr.Exec(l.Strings[i]) then begin
             try
               l.Delete(i);
             except
               logs.DebugLogs('Starting......: FATAL ERROR  (DELETE_MYSQLD_PARAMETERS) line 168 while deleting a value='+key);
             end;
               found:=true;
               break;
            end;
      end;



  end;

if found then logs.WriteToFile(L.Text,CNF_PATH());
l.free;
RegExpr.free;

end;
//#############################################################################
procedure tmysql_daemon.DELETE_PARAMETERS(key:string);
var
 RegExpr:TRegExpr;
 l:tstringlist;
 found:boolean;
 i:integer;
begin

  if not FileExists(CNF_PATH()) then begin
     logs.DebugLogs('Starting......: Unable to stat my.cnf (DELETE_MYSQLD_PARAMETERS)');
     exit();
  end;

  found:=false;
  l:=Tstringlist.Create;
  l.LoadFromFile(CNF_PATH());
  RegExpr:=TRegExpr.Create;
  RegExpr.Expression:=key;
  for i:=0 to l.Count-1 do begin

            if RegExpr.Exec(l.Strings[i]) then begin
             try
                logs.DebugLogs('Starting......: deleting entry '+l.Strings[i]);
               l.Delete(i);
             except
               logs.DebugLogs('Starting......: FATAL ERROR  (DELETE_MYSQLD_PARAMETERS) line 234 while deleting a value='+key);
             end;
               found:=true;
               break;
            end;
  end;
 if found then logs.WriteToFile(L.Text,CNF_PATH());
l.free;
RegExpr.free;


end;

//#############################################################################
procedure tmysql_daemon.SET_PARAMETERS(bigkey:string;key:string;value:string);
var Ini:TiniFile;
begin

  if not FileExists(CNF_PATH()) then exit();
  ini:=TiniFile.Create(CNF_PATH());
  ini.WriteString(bigkey,key,value);
  ini.UpdateFile;
  ini.free;
end;
//#############################################################################




function tmysql_daemon.SERVER_PARAMETERS(key:string):string;
var Ini:TMemIniFile;
begin
  result:='';
  if not FileExists(CNF_PATH()) then exit();
try
  ini:=TMemIniFile.Create(CNF_PATH());

except
      writeln('tmysql_daemon.SERVER_PARAMETERS() :: unable to open file ',CNF_PATH());
      exit;
end;
  result:=ini.ReadString('mysqld',key,'');

  if length(result)=0 then result:=ini.ReadString('mysqld_safe',key,'');

  if length(result)=0 then begin
      writeln('Starting......: cannot found value for '+key);
     result:=SERVER_DEFAULTS(key);
      writeln('Starting......: defautl value for '+key+' "'+result+'"');
  end;

  ini.free;
end;
//#############################################################################
function tmysql_daemon.SERVER_DEFAULTS(key:string):string;
var
   tmp_file:string;
   tmpd:string;
   RegExpr:TRegExpr;
begin
  result:='';
  if not FileExists(SYS.LOCATE_mysqld_bin()) then exit();
  tmp_file:=logs.FILE_TEMP();
  fpsystem(SYS.LOCATE_mysqld_bin() + ' --print-defaults >'+tmp_file+ ' 2>&1');
  tmpd:=logs.ReadFromFile(tmp_file)+' ';
  logs.DeleteFile(tmp_file);
  RegExpr:=TRegExpr.Create;
  RegExpr.Expression:='--'+key+'=(.+?)\s+';
  if RegExpr.Exec(tmpd) then begin
     logs.Debuglogs('SERVER_DEFAULTS:: ' + key+ '=' + RegExpr.Match[1]);
     result:=RegExpr.Match[1];
  end else begin
     logs.Debuglogs('SERVER_DEFAULTS:: unable to determine ' +  RegExpr.Expression + ' in ' + tmpd);
  end;
  
  RegExpr.free;
end;
//#############################################################################
procedure tmysql_daemon.CleanMyCnf();
var
   RegExpr:TRegExpr;
   l:Tstringlist;
   i:integer;
   path:string;
   f:boolean;
begin
     path:=CNF_PATH();
     if not FileExists(path) then begin
         logs.Syslogs('Starting......: Mysql unable to stat my.cnf');
         exit;
     end;
     f:=false;
     l:=Tstringlist.Create;
     l.LoadFromFile(path);
     RegExpr:=TRegExpr.Create;
     RegExpr.Expression:='^\=(.+)';
     for i:=0 to l.Count-1 do begin
        if RegExpr.Exec(l.Strings[i]) then begin
          logs.Syslogs('Starting......: check '+RegExpr.Match[1] );
          l.Strings[i]:=RegExpr.Match[1];
          f:=true;
        end;
     end;

    if f then logs.WriteToFile(l.Text,path);
    l.free;
    RegExpr.free;

end;
//#############################################################################

procedure tmysql_daemon.SERVICE_STOP();
var
   pid:string;
   mysqladmin:string;
   mysqladmin_pid:string;
   mysqlbin:string;
   count:integer;
   user,password,cmdlineP,cmdline:string;
begin

mysqladmin:=SYS.LOCATE_MYSQL_ADMIN();
mysqlbin:=SYS.LOCATE_mysqld_bin();

  if not FileExists(mysqladmin) then begin
     logs.Syslogs('Unable to stat mysqladmin program !!!');
     exit;
  end;

    user:=SYS.MYSQL_INFOS('database_admin');
    password:=SYS.MYSQL_INFOS('database_password');
   pid:=PID_NUM();




 if(length(password)>0) then begin
        password:=AnsiReplaceText(password,'&','\&');
       password:=AnsiReplaceText(password,'<','\<');
       password:=AnsiReplaceText(password,'>','\>');
       password:=AnsiReplaceText(password,'$','\$');
       password:=AnsiReplaceText(password,'!','\!');
       cmdlineP:=' --password='+password;
  end;


  if not SYS.PROCESS_EXIST(pid) then begin
     writeln('Stopping mysql...............: Already stopped');
     TUNE_MYSQL();
     exit;
  end;

  writeln('Stopping mysql...............: ' + pid + ' PID');
  cmdline:=mysqladmin +' --user='+user+cmdlineP+' shutdown &';
  logs.Debuglogs(cmdline);
  fpsystem(cmdline);
  sleep(100);
  mysqladmin_pid:=SYS.PIDOF(mysqladmin);
  count:=0;
  SYS:=Tsystem.Create();

   while SYS.PROCESS_EXIST(mysqladmin_pid) do begin
        try begin
            SYS.Free;
            SYS:=Tsystem.Create();
            pid:=SYS.PIDOF(mysqladmin)
        end;
        except
           writeln('Stopping mysql...............: Fatal error SYS.PIDOF() function');
           continue;
        end;
        sleep(500);
        count:=count+1;
        if count>40 then begin
            writeln('Stopping mysql...............: timeout with mysql_admin');
            break;
        end;
  end;

  count:=0;
  writeln('');
  pid:=SYS.PIDOF(mysqlbin);
  if SYS.PROCESS_EXIST(pid) then begin
     writeln('Stopping mysql...............: killing smoothly mysql PID '+pid);
     while SYS.PROCESS_EXIST(pid) do begin
           fpsystem('/bin/kill -15 '+pid);
           sleep(400);
           count:=count+1;
           if count>30 then begin
              writeln('');
              writeln('Stopping mysql...............: timeout while killing smoothly processes');
              break;
            end;
            sys.free;
            SYS:=Tsystem.Create();
            pid:=SYS.PIDOF(mysqlbin);
     end;
  end;


  sys.free;
  SYS:=Tsystem.Create();
  pid:=SYS.PIDOF(mysqlbin);
  if length(pid)>0 then begin
     writeln('Stopping mysql...............: Force killing mysql PID '+pid);
     while length(pid)>0 do begin
           fpsystem('/bin/kill -9 '+pid);
           sleep(400);
           count:=count+1;
           write('.');
           if count>30 then begin
              writeln('');
              writeln('Stopping mysql...............: timeout while Force killing processes');
              break;
            end;
        sys.free;
        SYS:=Tsystem.Create();
        pid:=SYS.PIDOF(mysqlbin);
        pid:=SYS.PROCESSES_LIST(mysqlbin);
     end;
  end else begin
       writeln('Stopping mysql...............: stopped');
  end;

  if FIleExists('/usr/sbin/mysqlmanager') then begin
     pid:=SYS.PROCESSES_LIST('/usr/sbin/mysqlmanager');              
     if length(pid)>0 then begin
        writeln('Stopping mysql...............: mysqlmanager: pid(s)'+pid);
        fpsystem('/bin/kill -9 '+pid);
     end;
  end;


  sys.free;
  SYS:=Tsystem.Create();
  pid:=SYS.PIDOF(mysqlbin);
  if not SYS.PROCESS_EXIST(pid) then begin
     writeln('Stopping mysql...............: success');
  end else begin
      writeln('Stopping mysql...............: failed');
  end;

  
  
end;
//##################################################################################
function tmysql_daemon.VERSION():string;
var
   RegExpr:TRegExpr;
   x:string;
   tmpstr:string;
begin
  RegExpr:=TRegExpr.Create;
  x:=logs.FILE_TEMP();
  fpsystem(sys.LOCATE_mysqld_bin() + ' --version >' + x + ' 2>&1');
  tmpstr:=logs.ReadFromFile(x);
  logs.DeleteFile(x);
  RegExpr.Expression:='Ver\s+(.+?)\s+';
  if RegExpr.Exec(tmpstr) then result:=RegExpr.Match[1];
  RegExpr.Free;
end;
//##############################################################################
FUNCTION tmysql_daemon.STATUS():string;
var
pidpath:string;
begin
   SYS.MONIT_DELETE('APP_MYSQL_ARTICA');
   SYS.MONIT_DELETE('MYSQL_CLUSTER_REPLICA');
   SYS.MONIT_DELETE('APP_MYSQL_CLUSTER_MGMT');
   pidpath:=logs.FILE_TEMP();
   fpsystem(SYS.LOCATE_PHP5_BIN()+' /usr/share/artica-postfix/exec.status.php --mysql >'+pidpath +' 2>&1');
   result:=logs.ReadFromFile(pidpath);
   logs.DeleteFile(pidpath);

end;
//##############################################################################
FUNCTION tmysql_daemon.CHECK_ERRORS_INFILE(path:string):boolean;
var
   i     :integer;
   l:TstringList;
   RegExpr:TRegExpr;
begin
   result:=false;
   if not FileExists(path) then begin
      writeln('tmysql_daemon.CHECK_ERRORS_INFILE:: unable to stat '+path);
      exit;
   end;

    l:=Tstringlist.Create;
    l.LoadFromFile(path);
    RegExpr:=TRegExpr.Create;

    for i:=0 to l.Count-1 do begin
       RegExpr.Expression:='Can''t connect to local MySQL server through socket';
       if RegExpr.Exec(l.Strings[i]) then begin
          l.free;
          logs.Debuglogs('CHECK_ERRORS_INFILE:: Connect to local MySQL server through socket failed');
          result:=true;
          exit;
       end;


    end;

end;
//##############################################################################

procedure tmysql_daemon.CHANGE_MYSQL_ROOT();
var ChangeMysqlDir:string;
begin
   ChangeMysqlDir:=SYS.GET_INFO('ChangeMysqlDir');
   if ChangeMysqlDir='/var/lib/mysql' then exit;
   if not DirectoryExists(ChangeMysqlDir) then begin
      writeln('CHANGE_MYSQL_ROOT:: ',ChangeMysqlDir,' No such directory');
      exit;
   end;
   SERVICE_STOP();
   SERVICE_STOP();
   fpsystem('/bin/touch /etc/artica-postfix/mysql.stop');
   fpsystem('/bin/cp -rf /var/lib/mysql/* '+ChangeMysqlDir+'/');
   fpsystem('/bin/rm -rf /var/lib/mysql');
   fpsystem('/bin/ln -s '+ChangeMysqlDir+' /var/lib/mysql');
   fpsystem('/bin/rm /etc/artica-postfix/mysql.stop');
   fpsystem('/bin/chmod 755 '+ChangeMysqlDir);
   fpsystem('/bin/chmod -R 755 '+ChangeMysqlDir+'/*');
   fpsystem('/bin/chown mysql:mysql '+ChangeMysqlDir);
   fpsystem('/bin/chown -R mysql:mysql '+ChangeMysqlDir+'/*');
   SERVICE_START();

end;

procedure tmysql_daemon.SERVICE_START(nochecks:boolean);
var
   pid,cmd   :string;
   Datadir,logbin,FileTemp,syslog,EnableMysqlFeatures:string;
   artica_backup_pid:string;
   processname:string;
   pid_file:string;
   socket:string;
   mysql_user:string;
   logpathstring:string;
   ldap:topenldap;
   mysql_install_db:string;
   count:integer;
   ChangeMysqlDir:string;
   bind_address,bind_address2:string;
   MysqlRemoveidbLogs:integer;

begin

 if FileExists('/etc/artica-postfix/mysql.stop') then begin
    logs.DebugLogs('Starting......: Mysql locked, exiting');
    exit;
 end;
logpathstring:='';
 FileTemp:=artica_path+'/ressources/logs/mysql.start.daemon';
 mysql_install_db:=SYS.LOCATE_GENERIC_BIN('mysql_install_db');
 processname:=ExtractFileName(ParamStr(0));
if not FileExists(SYS.LOCATE_mysqld_bin()) then begin
   logs.DebugLogs('Starting......: Mysql is not installed, abort');
   exit;
end;

if SYS.isoverloadedTooMuch() then begin
   logs.DebugLogs('Starting......: System is overloaded');
   exit;
end;

EnableMysqlFeatures:=SYS.GET_INFO('EnableMysqlFeatures');

if length(EnableMysqlFeatures)=0 then begin
   SYS.set_INFO('EnableMysqlFeatures','1');
   EnableMysqlFeatures:='1';
end;

if  SYS.GET_INFO('MysqlTooManyConnections')='1' then begin
    logs.DebugLogs('Starting......: Mysql MysqlTooManyConnections=1, abort');
    exit;
end;





if processname<>'artica-backup' then begin
   artica_backup_pid:=SYS.PIDOF('artica-backup');
   if SYS.PROCESS_EXIST(artica_backup_pid) then begin
      logs.Syslogs('Starting......: Mysql is disabled until artica-backup is running');
      exit;
   end;
end;

if SYS.PROCESS_EXIST(PID_NUM()) then begin
     if SYS.GET_INFO('EnableMysqlFeatures')='0' then begin
        logs.Syslogs('Starting......: Mysql is disabled by "EnableMysqlFeatures" stop it...');
        SERVICE_STOP();
     end;
     logs.DebugLogs('Starting......: Mysql is already running using PID ' + PID_NUM() + '...');
     exit();
  end;
  
if SYS.GET_INFO('EnableMysqlFeatures')='0' then begin
   logs.Debuglogs('Starting......: Mysql is disabled by "EnableMysqlFeatures"...');
   exit;
end;


pid_file:=SERVER_PARAMETERS('pid-file');
socket:=SERVER_PARAMETERS('socket');
if length(pid_file)=0 then SET_MYSQLD_PARAMETERS('pid-file','/var/run/mysqld/mysqld.pid');
SET_MYSQLD_PARAMETERS('socket','/var/run/mysqld/mysqld.sock');
ForceDirectories('/var/log/mysql');



   logbin:=SERVER_PARAMETERS('log_bin');
   mysql_user:=SERVER_PARAMETERS('user');
   fpsystem('/bin/chmod 777 /tmp');
   if length(mysql_user)=0 then mysql_user:='mysql';
   if length(logbin)=0 then logbin:=SERVER_PARAMETERS('log');

   bind_address:='';
   bind_address2:=SERVER_PARAMETERS('bind-address');
   if length(trim(bind_address2))=0 then begin
      bind_address:=' --bind-address=127.0.0.1';
      bind_address2:='127.0.0.1';
   end;

   datadir:=SERVER_PARAMETERS('datadir');
   logbin:=ExtractFileDir(logbin);
   syslog:=SYS.LOCATE_SYSLOG_PATH();
   logs.DebugLogs('Starting......: tuning '+ CNF_PATH() );
   TUNE_MYSQL();
   logs.DebugLogs('Starting......: Mysql my.cnf........:' +CNF_PATH());
   logs.DebugLogs('Starting......: Mysql init.d........:' +INIT_PATH());
   logs.DebugLogs('Starting......: Mysql Pid path......:' +SERVER_PARAMETERS('pid-file'));
   logs.DebugLogs('Starting......: Mysql log-bin.......:' +logbin);
   logs.DebugLogs('Starting......: datadir.............:' +datadir);
   logs.DebugLogs('Starting......: syslog..............:' +syslog);
   logs.DebugLogs('Starting......: socket..............:' +socket);
   logs.DebugLogs('Starting......: user................:' +mysql_user);
   logs.DebugLogs('Starting......: pid-file............:' +pid_file);
   logs.DebugLogs('Starting......: LOGS ENABLED........:' +IntTostr(EnableMysqlLog));
   logs.DebugLogs('Starting......: Daemon..............:' +daemon_bin_path);
   logs.DebugLogs('Starting......: Bind address........:' +bind_address2);

   if length(logbin)>0 then logs.OutputCmd('/bin/chown -R '+mysql_user+':'+mysql_user+' '+logbin);
   forcedirectories('/var/run/mysqld');
   logs.OutputCmd('/bin/chown -R '+mysql_user+':'+mysql_user+' /var/run/mysqld');
   logs.OutputCmd('/bin/chown -R '+mysql_user+':'+mysql_user+' /var/log/mysql');
   ChangeMysqlDir:=SYS.GET_INFO('ChangeMysqlDir');
   if length(ChangeMysqlDir)>0 then begin
      if DirectoryExists(ChangeMysqlDir) then begin
         fpsystem('/bin/chmod 755 '+ChangeMysqlDir);
         fpsystem('/bin/chmod -R 755 '+ChangeMysqlDir+'/*');
         fpsystem('/bin/chown mysql:mysql '+ChangeMysqlDir);
         fpsystem('/bin/chown -R mysql:mysql '+ChangeMysqlDir+'/*');
      end;
   end;


     if not TryStrToINt(SYS.GET_INFO('MysqlRemoveidbLogs'),MysqlRemoveidbLogs) then MysqlRemoveidbLogs:=0;
     if MysqlRemoveidbLogs=1 then begin
        fpsystem('/bin/mv /var/lib/mysql/ib_logfile* /tmp/');
        sys.set_INFO('MysqlRemoveidbLogs','0');
     end;
   if DirectoryExists(datadir) then logs.OutputCmd('/bin/chown -R '+mysql_user+':'+mysql_user+' '+datadir);
   CleanMyCnf();
   if(EnableMysqlLog=1) then logpathstring:=' --log=/var/log/mysql.log --log-slow-queries=/var/log/mysql-slow-queries.log --log-error=/var/log/mysql.error.log --log-warnings';
   if not FileExists('/var/log/mysql-slow-queries.log') then logs.OutputCmd('/bin/touch /var/log/mysql-slow-queries.log');
   if not FileExists('/var/log/mysql.error') then logs.OutputCmd('/bin/touch /var/log/mysql.error.log');
   if not FileExists('/var/log/mysql.log') then logs.OutputCmd('/bin/touch /var/log/mysql.log');
   if not FileExists('/var/log/mysql.warn') then logs.OutputCmd('/bin/touch /var/log/mysql.warn.log');

   logs.OutputCmd('/bin/chown '+mysql_user+':'+mysql_user+' /var/log/mysql-slow-queries.log');
   logs.OutputCmd('/bin/chown '+mysql_user+':'+mysql_user+' /var/log/mysql.error.log');
   logs.OutputCmd('/bin/chown '+mysql_user+':'+mysql_user+' /var/log/mysql.log');
   logs.OutputCmd('/bin/chown '+mysql_user+':'+mysql_user+' /var/log/mysql.warn.log');


   datadir:=SERVER_PARAMETERS('datadir');
   logs.DebugLogs('Starting......: Mysql Checking :' +datadir+'/mysql/host.frm');
   if not FileExists(datadir+'/mysql/host.frm') then begin
     if FileExists(mysql_install_db) then begin
        logs.Debuglogs('Starting......: Mysql installing default databases.');
        fpsystem(mysql_install_db);
     end else begin
         logs.DebugLogs('Starting......: unable to stat mysql_install_db');
     end;
   end;

   DELETE_PARAMETERS('skip-innodb');
   DELETE_PARAMETERS('skip-bdb');

   if innodb_file_per_table=1 then begin
       logs.DebugLogs('Starting......: Mysql using innodb file per table feature');
   end;

   if FileExists('/var/run/mysqld/mysqld.err') then logs.DeleteFile('/var/run/mysqld/mysqld.err');
   cmd:=daemon_bin_path+bind_address+logpathstring+ ' >/var/log/mysql/mysql.start.log 2>&1 &';
   fpsystem(cmd);
   pid:=PID_NUM();
   count:=0;
    while not SYS.PROCESS_EXIST(pid) do begin
     sleep(300);
     inc(count);
     if count>5 then begin
       logs.DebugLogs('Starting......: Mysql (timeout!!!)');
       logs.DebugLogs('Starting......: Mysql "'+cmd+'"');
       break;
     end;
      pid:=PID_NUM();
   end;

 pid:=PID_NUM();
 if not SYS.PROCESS_EXIST(pid) then begin
    logs.DebugLogs('Starting......: Mysql failed with command line '+daemon_bin_path +logpathstring+ ' &');
    if not nochecks then SERVICE_START(true);
 end else begin
   logs.DebugLogs('Starting......: Mysql success PID ' + pid);
   logs.DeleteFile(FileTemp);
 end;

end;
//############################################################################# #
function tmysql_daemon.checks_errors():boolean;
var
   l:Tstringlist;
   i:integer;
   RegExpr:TRegExpr;
begin
  result:=false;
  if not FileExists('/var/log/mysql/mysql.start.log') then exit(false);
  l:=Tstringlist.Create();
  l.LoadFromFile('/var/log/mysql/mysql.start.log');
  for i:=0 to l.Count-1 do begin
      if length(trim(l.Strings[i]))=0 then continue;
      RegExpr.Expression:='WARNING: The host ''(.+?)'' could not be looked up with resolveip';
      if RegExpr.Exec(l.Strings[i]) then begin
          SYS.ETC_HOSTS_ADD(RegExpr.Match[1],'127.0.0.1');
          RegExpr.free;
          l.free;
          exit(true);
      end;
      logs.DebugLogs('Starting......: Mysql '+l.Strings[i]);
  end;
          RegExpr.free;
          l.free;
end;




function tmysql_daemon.MON():string;
var
l:TstringList;
begin

if not FileExists(SYS.LOCATE_mysqld_bin()) then begin
   logs.DebugLogs('Starting......: Mysql is not installed, abort');
   exit;
end;

l:=TstringList.Create;

l.Add('check process '+ExtractFileName(SYS.LOCATE_mysqld_bin())+' with pidfile '+PID_PATH());
l.Add('group daemons');
l.Add('start program = "'+INIT_PATH()+' start"');
l.Add('stop program = "'+INIT_PATH()+' stop"');
l.Add('if 5 restarts within 5 cycles then timeout');

result:=l.Text;
l.free;

end;
//##############################################################################

procedure tmysql_daemon.TUNE_MYSQL();
begin
   if not FileExists(CNF_PATH()) then exit;
   fpsystem(SYS.LOCATE_PHP5_BIN()+' /usr/share/artica-postfix/exec.mysql.build.php '+CNF_PATH());
end;
//############################################################################# #
procedure tmysql_daemon.CleanIniMysql();
var
l:TstringList;
RegExpr:TRegExpr;
i:integer;
begin
    if not FileExists(CNF_PATH()) then exit;
    l:=TstringList.Create;
    l.LoadFromFile(CNF_PATH());
    RegExpr:=TRegExpr.Create;
    RegExpr.Expression:='^\=(.+)';
    for i:=0 to l.Count-1 do begin
        if RegExpr.Exec(l.Strings[i]) then begin
           l.Strings[i]:=RegExpr.Match[1];
        end;
    end;
    
    
    l.SaveToFile(CNF_PATH());
    l.Free;
    RegExpr.free;
end;
//############################################################################# #
procedure tmysql_daemon.REPAIR_DATABASES();
var
   l:TstringList;
   dir:string;
   i:Integer;
begin
     
 if not FileExists('/usr/bin/myisamchk') then begin
     LOGS.Syslogs('tmysql_daemon.REPAIR_DATABASES() unable to stat /usr/bin/myisamchk');
     exit;
  end;
  SERVICE_STOP();
  dir:=SERVER_PARAMETERS('datadir');


  if Not DirectoryExists(dir) then begin
       LOGS.Syslogs('tmysql_daemon.REPAIR_DATABASES() unable to stat '+dir);
       exit;
  end;


  l:=TstringList.Create;
  l.Add('amavis');
  l.Add('artica_backup');
  l.Add('artica_events');
  l.Add('mysql');
  l.Add('obm');
  l.Add('pommo');
  l.Add('roundcubemail');
  for i:=0 to l.Count-1 do begin
       if DirectoryExists(dir+'/'+l.Strings[i]) then begin
            logs.Debuglogs('REPAIR_DATABASES:: checking '+dir+'/'+l.Strings[i]+'/*.MYI');
            fpsystem('/usr/bin/myisamchk -r '+dir+'/'+l.Strings[i]+'/*.MYI');
       end;
  end;
  SERVICE_START();
end;
//############################################################################# #
procedure tmysql_daemon.cluster_management_saveconf();
var
   l:Tstringlist;
   s:Tstringlist;
   t:Tstringlist;
   NoOfReplicas,i:integer;
begin
  NoOfReplicas:=0;
 if EnableMysqlClusterManager=0 then begin
    logs.WriteToFile('#','/etc/mysql/ndb_mgmd.cnf');
    exit;
 end;

    s:=Tstringlist.Create;
    t:=Tstringlist.Create;           

    forceDirectories('/var/lib/mysql-cluster');
    fpsystem('/bin/chown -R mysql:mysql /var/lib/mysql-cluster');

 if FileExists('/etc/artica-postfix/settings/Daemons/MysqlReplicasList') then begin

    s.LoadFromFile('/etc/artica-postfix/settings/Daemons/MysqlReplicasList');
    for i:=0 to s.Count-1 do begin
       if length(trim(s.Strings[i]))>0 then begin
          if trim(s.Strings[i])='127.0.0.1' then continue;
          inc(NoOfReplicas);
          t.Add('[NDBD]');
          t.Add('HostName='+s.Strings[i]);
          t.Add('DataDir=/var/lib/mysql-cluster');
          t.Add('BackupDataDir=/var/lib/mysql-cluster');
          t.Add('DataMemory=512M');
          t.Add('[MYSQLD]');

       end;
    end;
end;

 l:=Tstringlist.Create;

 l.Add('[NDBD DEFAULT]');
 l.Add('NoOfReplicas='+IntToStr(NoOfReplicas));
 l.Add('DataMemory=80M');
 l.Add('IndexMemory=18M');
 l.Add('[MYSQLD DEFAULT]');
 l.Add('[NDB_MGMD DEFAULT]');
 l.add('DataDir=/var/lib/mysql-cluster');
 l.Add('[TCP DEFAULT]');
 l.Add('[NDB_MGMD]');
 l.Add('HostName='+SYS.GET_INFO('MysqlClusterManagerHostName'));
 l.Add(t.Text);
 logs.WriteToFile(l.Text,'/etc/mysql/ndb_mgmd.cnf');
 l.free;
 s.free;
 t.free;
end;
//############################################################################# #
procedure tmysql_daemon.cluster_replicat_saveconf();
var
   l:Tstringlist;
begin

 if EnableMysqlClusterReplicat=0 then begin
    logs.WriteToFile('#','/etc/mysql/ndb_mgmd.node.cnf');
    exit;
 end;

 l:=Tstringlist.Create;

 l.Add('[mysqld]');
 l.Add('ndbcluster');
 l.Add('ndb-connectstring='+SYS.GET_INFO('MysqlClusterManagerTarget'));
 logs.WriteToFile(l.Text,'/etc/mysql/ndb_mgmd.node.cnf');
 l.free;
end;
//############################################################################# #
function tmysql_daemon.PID_CLUSTER():string;
begin
   result:=SYS.PIDOF(SYS.LOCATE_NDB_MGMD);
end;
//############################################################################# #
function tmysql_daemon.PID_CLUSTER_REPLICAT():string;
begin
   result:=SYS.PIDOF(SYS.LOCATE_NDB);
end;
//############################################################################# #
procedure tmysql_daemon.CLUSTER_MANAGEMENT_STOP();
var
   pid:string;
   count:integer;
begin

if not FileExists(SYS.LOCATE_NDB_MGMD) then begin
   writeln('Stopping mysql-cluster.......: Mysql-cluster is not installed');
   exit;
end;

pid:=PID_CLUSTER();

if not SYS.PROCESS_EXIST(pid) then begin
      writeln('Stopping mysql-cluster.......: Mysql-cluster already stopped');
      exit;
end;

count:=0;
while SYS.PROCESS_EXIST(pid) do begin
        sleep(100);
        inc(count);
        if length(trim(pid))=0 then break;
        logs.OutputCmd('/bin/kill '+pid);
        if count>30 then begin
           writeln('Stopping mysql-cluster.......: Mysql-cluster time-out');
           break;
        end;
        pid:=trim(PID_CLUSTER());
end;

pid:=PID_CLUSTER();

if not SYS.PROCESS_EXIST(pid) then begin
      writeln('Stopping mysql-cluster.......: Mysql-cluster stopped');
      exit;
end else begin
     writeln('Stopping mysql-cluster.......: Mysql-cluster failed to stop');
end;
end;
//############################################################################# #
procedure tmysql_daemon.CLUSTER_REPLICA_STOP();
var
   pid:string;
   count:integer;
begin

if not FileExists(SYS.LOCATE_NDB) then begin
   writeln('Stopping mysql-cluster.......: Mysql-cluster replica is not installed');
   exit;
end;

pid:=PID_CLUSTER_REPLICAT();

if not SYS.PROCESS_EXIST(pid) then begin
      writeln('Stopping mysql-cluster.......: Mysql-cluster replica already stopped');
      exit;
end;

        count:=0;
while SYS.PROCESS_EXIST(pid) do begin
        sleep(100);
        inc(count);
        if length(trim(pid))=0 then break;
        logs.OutputCmd('/bin/kill '+pid);
        if count>30 then begin
           writeln('Stopping mysql-cluster.......: Mysql-cluster replica time-out');
           break;
        end;
        pid:=trim(PID_CLUSTER_REPLICAT());
end;

pid:=PID_CLUSTER_REPLICAT();

if not SYS.PROCESS_EXIST(pid) then begin
      writeln('Stopping mysql-cluster.......: Mysql-cluster replica stopped');
      exit;
end else begin
     writeln('Stopping mysql-cluster.......: Mysql-cluster replica failed to stop');
end;
end;
//############################################################################# #
procedure tmysql_daemon.CLUSTER_REPLICA_START();
var
   cmd,pid,processname,artica_backup_pid:string;
   count    :integer;
   MysqlClusterReplicatID:integer;
begin


if not FileExists(SYS.LOCATE_NDB()) then begin
   logs.DebugLogs('Starting......: Mysql-cluster replica is not installed, abort');
   exit;
end;

if EnableMysqlClusterReplicat<>1 then begin
    logs.DebugLogs('Starting......: Mysql-cluster replica is not enabled, abort');
    CLUSTER_REPLICA_STOP();
    exit;
end;



 processname:=ExtractFileName(ParamStr(0));
if processname<>'artica-backup' then begin
   artica_backup_pid:=SYS.PIDOF('artica-backup');
   if SYS.PROCESS_EXIST(artica_backup_pid) then begin
      logs.Syslogs('Starting......: Mysql-cluster replicat is disabled until artica-backup is running');
      exit;
   end;
end;

pid:=PID_CLUSTER_REPLICAT();

if SYS.PROCESS_EXIST(pid) then begin
     logs.DebugLogs('Starting......: Mysql-cluster replica already running PID '+pid);
     exit;
  end;

    forceDirectories('/var/lib/mysql-cluster');
    fpsystem('/bin/chown -R mysql:mysql /var/lib/mysql-cluster');

if not TryStrToInt(SYS.GET_INFO('MysqlClusterReplicatID'),MysqlClusterReplicatID) then MysqlClusterReplicatID:=2;
logs.DebugLogs('Starting......: Mysql-cluster replica id '+IntToStr(MysqlClusterReplicatID));
logs.DebugLogs('Starting......: Mysql-cluster management server "'+ SYS.GET_INFO('MysqlClusterManagerTarget')+'"');
cluster_management_saveconf();
cmd:=SYS.LOCATE_NDB +' --ndb-nodeid='+IntToStr(MysqlClusterReplicatID)+' --ndb-mgmd-host='+SYS.GET_INFO('MysqlClusterManagerTarget')+' &';
logs.Debuglogs(cmd);
fpsystem(cmd);
pid:=PID_CLUSTER_REPLICAT();
  count:=0;
  while not SYS.PROCESS_EXIST(pid) do begin
     sleep(150);
     inc(count);
     if count>10 then begin
        writeln('');
        logs.DebugLogs('Starting......: Mysql-cluster replica');
        break;
     end;
     write('.');
     pid:=PID_CLUSTER_REPLICAT();
  end;

pid:=PID_CLUSTER_REPLICAT();
if SYS.PROCESS_EXIST(pid) then begin
     logs.DebugLogs('Starting......: Mysql-cluster replica success running PID '+pid);
     exit;
 end else begin
 logs.DebugLogs('Starting......: Mysql-cluster replica failed');
end;
end;
//############################################################################# #
procedure tmysql_daemon.CLUSTER_MANAGEMENT_START();
var
   cmd,pid,processname,artica_backup_pid:string;
   count     :integer;
   MysqlClusterManagerID:integer;
begin


if not FileExists(SYS.LOCATE_NDB_MGMD) then begin
   logs.DebugLogs('Starting......: Mysql-cluster is not installed, abort');
   exit;
end;

if SYS.isoverloadedTooMuch() then begin
   logs.DebugLogs('Starting......: System is overloaded');
   exit;
end;

if EnableMysqlClusterManager<>1 then begin
    logs.DebugLogs('Starting......: Mysql-cluster is not enabled, abort');
    CLUSTER_MANAGEMENT_STOP();
    exit;
end;



 processname:=ExtractFileName(ParamStr(0));
if processname<>'artica-backup' then begin
   artica_backup_pid:=SYS.PIDOF('artica-backup');
   if SYS.PROCESS_EXIST(artica_backup_pid) then begin
      logs.Syslogs('Starting......: Mysql-cluster is disabled until artica-backup is running');
      exit;
   end;
end;

pid:=PID_CLUSTER();

if SYS.PROCESS_EXIST(pid) then begin
     logs.DebugLogs('Starting......: Mysql-cluster already running PID '+pid);
     exit;
  end;

if not TryStrToInt(SYS.GET_INFO('MysqlClusterManagerID'),MysqlClusterManagerID) then MysqlClusterManagerID:=1;
logs.DebugLogs('Starting......: Mysql-cluster id '+IntToStr(MysqlClusterManagerID));
logs.DebugLogs('Starting......: Mysql-cluster save configuration file..');
cluster_replicat_saveconf();
cmd:=SYS.LOCATE_NDB_MGMD() +' --ndb-nodeid='+IntToStr(MysqlClusterManagerID)+' --config-file=/etc/mysql/ndb_mgmd.cnf &';
logs.Debuglogs(cmd);
fpsystem(cmd);

pid:=PID_CLUSTER();
  count:=0;
  while not SYS.PROCESS_EXIST(pid) do begin
     sleep(150);
     inc(count);
     if count>10 then begin
        writeln('');
        logs.DebugLogs('Starting......: Mysql-cluster replica');
        break;
     end;
     write('.');
     pid:=PID_CLUSTER();
  end;

pid:=PID_CLUSTER();
if SYS.PROCESS_EXIST(pid) then begin
     logs.DebugLogs('Starting......: Mysql-cluster success running PID '+pid);
     exit;
 end else begin
 logs.DebugLogs('Starting......: Mysql-cluster failed');
end;


end;
//############################################################################# #
procedure tmysql_daemon.CHANGE_ROOT_PASSWORD(password:string);
var
pid:string;
mysqld_bin:string;
sql:string;
count:integer;
begin
if not FileExists(SYS.LOCATE_mysqld_bin()) then begin
   writeln('Mysql is not installed...');
   exit;
end;

if not FileExists('/usr/bin/mysqld_safe') then begin
   writeln('mysqld_safe is not installed...');
   exit;
end;

  mysqld_bin:=SYS.LOCATE_mysqld_bin();
  writeln('Stopping mysql daemon...');
  SERVICE_STOP();
  writeln('running in --skip-grant-tables mode');
  fpsystem('/usr/bin/mysqld_safe --skip-grant-tables &');
  count:=0;
  pid:=SYS.PIDOF(mysqld_bin);
  while not SYS.PROCESS_EXIST(pid) do begin
        sleep(500);
        count:=count+1;

        if count>80 then begin
            writeln('running in --skip-grant-tables mode failed');
            exit;
        end;
        pid:=SYS.PIDOF(mysqld_bin);
  end;
 writeln('running in --skip-grant-tables mode width PID '+pid);
 
 
 sql:='update user set password = password("'+password+'") where user = "root"';
 logs.QUERY_SQL(pchar(sql),'mysql');
 writeln('Success...stopping grant mode');
 fpsystem('/bin/kill '+pid);
   count:=0;
  while SYS.PROCESS_EXIST(pid) do begin
        sleep(500);
        count:=count+1;
        if count>80 then break;
        pid:=SYS.PIDOF(mysqld_bin);
  end;
  count:=0;
   SYS.set_MYSQL('database_admin','root');
   SYS.set_MYSQL('database_password',password);
   writeln('Starting mysql');
   SERVICE_START();
   fpsystem('/etc/init.d/artica-postfix restart &');
end;
//##############################################################################
procedure tmysql_daemon.SSL_KEY();
var
   openssl:string;
   tmp,cf_path,cmd,CertificateMaxDays,tmpstr:string;
   ldap:topenldap;
   sslconf:TiniFile;
   servername,extensions:string;
   input_password:string;
begin
SYS:=Tsystem.Create();
ForceDirectories('/etc/ssl/certs/mysql');
tmp:=logs.FILE_TEMP();
ldap:=Topenldap.Create;
logs.WriteToFile(ldap.ldap_settings.password,tmp);
SYS.OPENSSL_CERTIFCATE_CONFIG();
cf_path:=SYS.OPENSSL_CONFIGURATION_PATH();
openssl:=SYS.LOCATE_OPENSSL_TOOL_PATH();
CertificateMaxDays:=SYS.GET_INFO('CertificateMaxDays');
if length(SYS.OPENSSL_CERTIFCATE_HOSTS())>0 then extensions:=' -extensions HOSTS_ADDONS ';
if length(CertificateMaxDays)=0 then CertificateMaxDays:='730';
servername:=GetHostname();
sslconf:=TiniFile.Create(cf_path);
input_password:=sslconf.ReadString('req','input_password','');

fpsystem('/bin/rm -f /etc/ssl/certs/mysql/*');

cmd:=openssl+' req -new -x509 -passout pass:'+input_password+' -config '+cf_path+extensions+' -keyout /var/lib/mysql/mysql-ca-key.pem -out /var/lib/mysql/mysql-ca-cert.pem -days '+CertificateMaxDays;
logs.Debuglogs('Starting......: Mysql ssl: '+cmd);
fpsystem(cmd);

cmd:=openssl+' req -new -passout pass:'+input_password+' -config '+cf_path+extensions+' -keyout /var/lib/mysql/mysql-server-key.pem -out /var/lib/mysql/mysql-server-req.pem -days '+CertificateMaxDays;
logs.Debuglogs('Starting......: Mysql ssl: '+cmd);
fpsystem(cmd);

cmd:=openssl+' x509 -req -in /var/lib/mysql/mysql-server-req.pem -passin pass:'+input_password+' -days 3600 -CA /var/lib/mysql/mysql-ca-cert.pem -CAkey /var/lib/mysql/mysql-ca-key.pem -set_serial 01 -out /var/lib/mysql/mysql-server-cert.pem';
logs.Debuglogs('Starting......: Mysql ssl: '+cmd);
fpsystem(cmd);

cmd:=openssl+' req -new -passout pass:'+input_password+' -config '+cf_path+extensions+' -keyout /var/lib/mysql/mysql-client-key.pem -out /var/lib/mysql/mysql-client-req.pem -days '+CertificateMaxDays;
logs.Debuglogs('Starting......: Mysql ssl: '+cmd);
fpsystem(cmd);

cmd:=openssl+' x509 -req -in /var/lib/mysql/mysql-client-req.pem -passin pass:'+input_password+' -days '+CertificateMaxDays+' -CA /var/lib/mysql/mysql-ca-cert.pem -CAkey /var/lib/mysql/mysql-ca-key.pem -set_serial 01 -out /var/lib/mysql/mysql-client-cert.pem';
logs.Debuglogs('Starting......: Mysql ssl: '+cmd);
fpsystem(cmd);

cmd:=openssl+' rsa -passin pass:'+input_password+' -in /var/lib/mysql/mysql-server-key.pem -out /var/lib/mysql/mysql-server-key.pem';
logs.Debuglogs('Starting......: Mysql ssl: '+cmd);
fpsystem(cmd);

cmd:=openssl+' rsa -passin pass:'+input_password+' -in /var/lib/mysql/mysql-client-key.pem -out /var/lib/mysql/mysql-client-key.pem';
logs.Debuglogs('Starting......: Mysql ssl: '+cmd);
fpsystem(cmd);

fpsystem('/bin/chown mysql:mysql /var/lib/mysql/*.pem');
forceDirectories('/etc/ssl/certs/mysql-client-download');
fpsystem('/bin/cp -f /var/lib/mysql/mysql-ca-cert.pem /etc/ssl/certs/mysql-client-download/cacert.pem');
fpsystem('/bin/cp -f /var/lib/mysql/mysql-client-cert.pem /etc/ssl/certs/mysql-client-download/client-cert.pem');
fpsystem('/bin/cp -f /var/lib/mysql/mysql-client-key.pem /etc/ssl/certs/mysql-client-download/client-key.pem');
SetCurrentDir('/etc/ssl/certs/mysql-client-download');
logs.DeleteFile('/etc/ssl/certs/mysql-client-download/mysql-ssl-client.tar');
fpsystem('/bin/tar -cf mysql-ssl-client.tar *');
SetCurrentDir('/root');


end;
//##############################################################################


{procedure tmysql_daemon.CleanIniMysql();

  root    :=MYSQL_INFOS('database_admin') +#0;
  password:=MYSQL_INFOS('database_password') +#0;
  port    :=MYSQL_SERVER_PARAMETERS_CF('port') +#0;
  server  :=MYSQL_INFOS('mysql_server') +#0;
 }

end.
