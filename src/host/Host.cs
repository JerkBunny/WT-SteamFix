using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Text;

[assembly: AssemblyTitle("WT-SteamFix")]
[assembly: AssemblyDescription("War Thunder x Steam 启动修复助手 / Launcher fix for Steam")]
[assembly: AssemblyProduct("WT-SteamFix")]
[assembly: AssemblyCompany("")]
[assembly: AssemblyVersion("3.3.0.0")]
[assembly: AssemblyFileVersion("3.3.0.0")]
[assembly: AssemblyInformationalVersion("测试中 Beta")]

static class Program
{
    static string ExeDir()
    {
        string d = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        if (string.IsNullOrEmpty(d)) d = Directory.GetCurrentDirectory();
        return d;
    }

    static bool CanWrite(string dir)
    {
        try
        {
            Directory.CreateDirectory(dir);
            string probe = Path.Combine(dir, ".write_test_" + Guid.NewGuid().ToString("N") + ".tmp");
            File.WriteAllText(probe, "x");
            File.Delete(probe);
            return true;
        }
        catch { return false; }
    }

    static void ExtractResource(string resourceName, string destPath)
    {
        using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream(resourceName))
        {
            if (s == null) throw new Exception("missing embedded resource: " + resourceName);
            string dir = Path.GetDirectoryName(destPath);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
            using (FileStream fs = File.Create(destPath)) { s.CopyTo(fs); }
        }
    }

    static void EnsureSteamCmd(string targetDir)
    {
        string exe = Path.Combine(targetDir, "steamcmd.exe");
        if (File.Exists(exe)) return;
        Directory.CreateDirectory(targetDir);
        string zip = Path.Combine(targetDir, "steamcmd.zip");
        ExtractResource("steamcmd.zip", zip);
        ZipFile.ExtractToDirectory(zip, targetDir);
        try { File.Delete(zip); } catch { }
    }

    // 优先复用本机已有的 steamcmd（免去首次 40MB 自更新）
    static string FindExistingSteamCmd(string toolRoot)
    {
        string[] candidates = new string[]
        {
            Path.Combine(toolRoot, "steamcmd"),
            Path.Combine(toolRoot, ".runtime", "steamcmd"),
            Path.Combine(toolRoot, "..", "steamcmd"),
            Path.Combine(toolRoot, "..", "..", "steamcmd"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "WT-SteamFix", "steamcmd")
        };
        foreach (string d in candidates)
        {
            try
            {
                string full = Path.GetFullPath(d);
                string exe = Path.Combine(full, "steamcmd.exe");
                if (File.Exists(exe)) return exe;
            }
            catch { }
        }
        return null;
    }

    static string Quote(string s)
    {
        if (s.IndexOf(' ') < 0 && s.IndexOf('"') < 0) return s;
        return "\"" + s.Replace("\"", "\\\"") + "\"";
    }

    [STAThread]
    static int Main(string[] args)
    {
        try
        {
            string exeDir = ExeDir();

            // 优先便携模式：所有东西都在 exe 旁边；目录不可写时退回 %LOCALAPPDATA%
            string toolRoot = exeDir;
            if (!CanWrite(exeDir))
            {
                toolRoot = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "WT-SteamFix");
                Directory.CreateDirectory(toolRoot);
            }
            string runtimeDir = Path.Combine(toolRoot, ".runtime");
            Directory.CreateDirectory(runtimeDir);

            string script = Path.Combine(runtimeDir, "WT-SteamFix.ps1");
            ExtractResource("WT-SteamFix.ps1", script);

            string scExe = FindExistingSteamCmd(toolRoot);
            if (scExe == null)
            {
                string scDir = Path.Combine(runtimeDir, "steamcmd");
                EnsureSteamCmd(scDir);
                scExe = Path.Combine(scDir, "steamcmd.exe");
            }

            Environment.SetEnvironmentVariable("WT_TOOLROOT", toolRoot);
            Environment.SetEnvironmentVariable("WT_STEAMCMD", scExe);

            StringBuilder sb = new StringBuilder();
            sb.Append("-NoProfile -ExecutionPolicy Bypass -File \"");
            sb.Append(script);
            sb.Append('"');
            foreach (string a in args) { sb.Append(' '); sb.Append(Quote(a)); }

            ProcessStartInfo psi = new ProcessStartInfo("powershell.exe", sb.ToString());
            psi.UseShellExecute = false;
            psi.WorkingDirectory = toolRoot;

            Process p = Process.Start(psi);
            p.WaitForExit();
            return p.ExitCode;
        }
        catch (Exception ex)
        {
            Console.WriteLine();
            Console.WriteLine("[x] " + ex.Message);
            Console.WriteLine();
            Console.WriteLine("按回车退出...");
            Console.ReadLine();
            return 1;
        }
    }
}
