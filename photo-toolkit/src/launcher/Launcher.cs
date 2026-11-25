using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Text;
using System.Windows.Forms;

/// <summary>
/// 照片工具 - 启动器
/// 读取同目录 config.ini 中的 photoRoot，拉起 app 子目录里的 PowerShell 界面。
/// </summary>
public class Launcher : Form
{
    private static readonly string DefaultRoot =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyPictures), "照片库");

    private readonly string baseDir;
    private readonly string configPath;
    private string root;
    private Label lblPath;
    private Label lblStatus;

    [STAThread]
    public static void Main(string[] args)
    {
        string dir = Path.GetDirectoryName(Application.ExecutablePath);

        // /test：只输出配置解析结果，便于自动化验证
        if (args.Length > 0 && args[0].ToLower() == "/test")
        {
            string cfg = Path.Combine(dir, "config.ini");
            string r = ReadRoot(cfg);
            string importer = Path.Combine(dir, @"app\PhotoImportGUI.ps1");
            string manager = Path.Combine(dir, @"app\PhotoManagerGUI.ps1");
            var sb = new StringBuilder();
            sb.AppendLine("baseDir=" + dir);
            sb.AppendLine("config=" + cfg);
            sb.AppendLine("photoRoot=" + r);
            sb.AppendLine("importerExists=" + File.Exists(importer));
            sb.AppendLine("managerExists=" + File.Exists(manager));
            sb.AppendLine("powershell=" + PowerShellPath());
            sb.AppendLine("powershellExists=" + File.Exists(PowerShellPath()));
            File.WriteAllText(Path.Combine(dir, "selftest.txt"), sb.ToString(), Encoding.UTF8);
            return;
        }

        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new Launcher(dir));
    }

    public Launcher(string dir)
    {
        baseDir = dir;
        configPath = Path.Combine(baseDir, "config.ini");

        Text = "照片工具";
        ClientSize = new Size(460, 250);
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedSingle;
        MaximizeBox = false;
        Font = new Font("Microsoft YaHei", 9f);

        var lblTitle = new Label();
        lblTitle.Text = "照片库位置";
        lblTitle.SetBounds(18, 16, 90, 20);
        Controls.Add(lblTitle);

        lblPath = new Label();
        lblPath.SetBounds(18, 38, 424, 40);
        lblPath.ForeColor = Color.SteelBlue;
        Controls.Add(lblPath);

        var btnImport = new Button();
        btnImport.Text = "导入照片";
        btnImport.SetBounds(18, 92, 130, 42);
        btnImport.Click += delegate { Launch(@"app\PhotoImportGUI.ps1", "-TargetRoot"); };
        Controls.Add(btnImport);

        var btnManage = new Button();
        btnManage.Text = "管理照片";
        btnManage.SetBounds(160, 92, 130, 42);
        btnManage.Click += delegate { Launch(@"app\PhotoManagerGUI.ps1", "-Root"); };
        Controls.Add(btnManage);

        var btnOpen = new Button();
        btnOpen.Text = "打开文件夹";
        btnOpen.SetBounds(302, 92, 140, 42);
        btnOpen.Click += delegate { OpenFolder(); };
        Controls.Add(btnOpen);

        var btnSet = new Button();
        btnSet.Text = "更改照片库路径...";
        btnSet.SetBounds(18, 148, 180, 30);
        btnSet.Click += delegate { ChangeRoot(); };
        Controls.Add(btnSet);

        lblStatus = new Label();
        lblStatus.SetBounds(18, 190, 424, 44);
        lblStatus.ForeColor = Color.Gray;
        Controls.Add(lblStatus);

        root = ReadRoot(configPath);
        if (!File.Exists(configPath)) SaveRoot(root);
        RefreshUi();
    }

    private void RefreshUi()
    {
        lblPath.Text = root;
        bool ok = Directory.Exists(root);
        lblStatus.Text = ok
            ? "就绪。导入：把存储卡里的照片整理进库；管理：浏览、打分、删除。"
            : "提示：该路径当前不存在，可点「更改照片库路径」重新指定。";
        lblStatus.ForeColor = ok ? Color.Gray : Color.Firebrick;
    }

    private static string ReadRoot(string path)
    {
        try
        {
            if (!File.Exists(path)) return DefaultRoot;
            foreach (string line in File.ReadAllLines(path, Encoding.UTF8))
            {
                string s = line.Trim();
                if (s.Length == 0 || s.StartsWith(";") || s.StartsWith("#")) continue;
                int i = s.IndexOf('=');
                if (i <= 0) continue;
                string k = s.Substring(0, i).Trim().ToLower();
                string v = s.Substring(i + 1).Trim().Trim('"');
                if (k == "photoroot" && v.Length > 0) return v;
            }
        }
        catch { }
        return DefaultRoot;
    }

    private void SaveRoot(string r)
    {
        try
        {
            var sb = new StringBuilder();
            sb.AppendLine("; 照片工具配置");
            sb.AppendLine("; 照片库根目录（导入目标 + 浏览根目录）");
            sb.AppendLine("photoRoot=" + r);
            File.WriteAllText(configPath, sb.ToString(), Encoding.UTF8);
        }
        catch (Exception ex) { MessageBox.Show("无法写入配置：" + ex.Message, "错误"); }
    }

    private void ChangeRoot()
    {
        using (var dlg = new FolderBrowserDialog())
        {
            dlg.Description = "选择照片库根目录";
            if (Directory.Exists(root)) dlg.SelectedPath = root;
            if (dlg.ShowDialog(this) == DialogResult.OK)
            {
                root = dlg.SelectedPath;
                SaveRoot(root);
                RefreshUi();
            }
        }
    }

    private void OpenFolder()
    {
        try
        {
            if (Directory.Exists(root)) Process.Start("explorer.exe", "\"" + root + "\"");
            else MessageBox.Show("路径不存在：\r\n" + root, "提示");
        }
        catch (Exception ex) { MessageBox.Show(ex.Message, "错误"); }
    }

    private static string PowerShellPath()
    {
        string windir = Environment.GetEnvironmentVariable("SystemRoot");
        if (string.IsNullOrEmpty(windir)) windir = @"C:\Windows";
        return Path.Combine(windir, @"System32\WindowsPowerShell\v1.0\powershell.exe");
    }

    private void Launch(string relScript, string paramName)
    {
        string script = Path.Combine(baseDir, relScript);
        if (!File.Exists(script))
        {
            MessageBox.Show("找不到程序文件：\r\n" + script + "\r\n\r\n请确认 app 子目录完整。", "错误");
            return;
        }
        string ps = PowerShellPath();
        if (!File.Exists(ps))
        {
            MessageBox.Show("找不到 Windows PowerShell：\r\n" + ps, "错误");
            return;
        }
        if (!Directory.Exists(root) &&
            MessageBox.Show("照片库路径不存在：\r\n" + root + "\r\n\r\n仍要继续启动吗？", "提示",
                MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes)
            return;

        try
        {
            var psi = new ProcessStartInfo();
            psi.FileName = ps;
            psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + script + "\" "
                          + paramName + " \"" + root + "\"";
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.WorkingDirectory = Path.GetDirectoryName(script);
            Process.Start(psi);
            lblStatus.Text = "已启动：" + Path.GetFileName(relScript);
            lblStatus.ForeColor = Color.SeaGreen;
        }
        catch (Exception ex) { MessageBox.Show("启动失败：" + ex.Message, "错误"); }
    }
}
