// The look of Agent Lid Closed for Windows: Windows 11 colours, fonts and icons, the tray menu's
// renderer, and the controls the Settings window is built from. C# 5, built with AgentLidClosed.cs.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using Microsoft.Win32;

namespace AgentLidClosed
{
    /// One set of colours: the app's windows follow "app mode", the tray menu follows the taskbar.
    class Palette
    {
        public bool Dark;
        public Color Window, Card, CardBorder, Text, SubText, Disabled, Accent, AccentHover, AccentPressed, OnAccent,
            Control, ControlHover, ControlPressed, ControlBorder, Hover, Selected, Separator, Good, Warn, Menu, MenuHover, MenuBorder, AccentTint;

        static Color Hex(int rgb) { return Color.FromArgb((rgb >> 16) & 0xff, (rgb >> 8) & 0xff, rgb & 0xff); }

        public static Color Blend(Color a, Color b, double amount)
        {
            return Color.FromArgb((int)(a.R + (b.R - a.R) * amount), (int)(a.G + (b.G - a.G) * amount), (int)(a.B + (b.B - a.B) * amount));
        }

        /// A Windows contrast theme: only the system's own colours, with borders where fills would
        /// otherwise tell things apart.
        public static Palette HighContrast()
        {
            Color window = SystemColors.Window, text = SystemColors.WindowText, highlight = SystemColors.Highlight;
            var p = new Palette { Dark = window.GetBrightness() < 0.5f, Accent = highlight };
            p.Window = window; p.Card = window; p.CardBorder = text;
            p.Text = text; p.SubText = text; p.Disabled = SystemColors.GrayText; p.OnAccent = SystemColors.HighlightText;
            p.AccentHover = highlight; p.AccentPressed = highlight; p.AccentTint = window;
            p.Control = SystemColors.Control; p.ControlHover = SystemColors.Control; p.ControlPressed = SystemColors.Control;
            p.ControlBorder = SystemColors.ControlText;
            p.Hover = window; p.Selected = window; p.Separator = text;
            p.Good = text; p.Warn = text;
            p.Menu = SystemColors.Menu; p.MenuHover = highlight; p.MenuBorder = SystemColors.MenuText;
            return p;
        }

        public static Palette Build(bool dark, Color accent)
        {
            var p = new Palette { Dark = dark, Accent = accent };
            if (dark)
            {
                p.Window = Hex(0x202020); p.Card = Hex(0x2B2B2B); p.CardBorder = Hex(0x1D1D1D);
                p.Text = Hex(0xFFFFFF); p.SubText = Hex(0xC5C5C5); p.Disabled = Hex(0x787878); p.OnAccent = Hex(0x000000);
                p.Control = Hex(0x373737); p.ControlHover = Hex(0x3D3D3D); p.ControlPressed = Hex(0x323232); p.ControlBorder = Hex(0x444444);
                p.Hover = Hex(0x2D2D2D); p.Selected = Hex(0x2D2D2D); p.Separator = Hex(0x3A3A3A);
                p.Good = Hex(0x6CCB5F); p.Warn = Hex(0xFCE100);
                p.Menu = Hex(0x2C2C2C); p.MenuHover = Hex(0x3A3A3A); p.MenuBorder = Hex(0x454545);
            }
            else
            {
                p.Window = Hex(0xF3F3F3); p.Card = Hex(0xFBFBFB); p.CardBorder = Hex(0xE5E5E5);
                p.Text = Hex(0x1B1B1B); p.SubText = Hex(0x5D5D5D); p.Disabled = Hex(0xA0A0A0); p.OnAccent = Hex(0xFFFFFF);
                p.Control = Hex(0xFEFEFE); p.ControlHover = Hex(0xF6F6F6); p.ControlPressed = Hex(0xF0F0F0); p.ControlBorder = Hex(0xD9D9D9);
                p.Hover = Hex(0xEAEAEA); p.Selected = Hex(0xEAEAEA); p.Separator = Hex(0xE5E5E5);
                p.Good = Hex(0x0F7B0F); p.Warn = Hex(0x9D5D00);
                p.Menu = Hex(0xF9F9F9); p.MenuHover = Hex(0xEAEAEA); p.MenuBorder = Hex(0xDADADA);
            }
            p.AccentHover = Blend(accent, p.Window, 0.1);
            p.AccentPressed = Blend(accent, p.Window, 0.2);
            p.AccentTint = Blend(p.Card, accent, dark ? 0.22 : 0.12);
            return p;
        }
    }

    /// Colours, fonts, glyphs and sizes shared by the tray and the windows, after Windows 11.
    static class Theme
    {
        [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
        [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
        [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr handle);

        // Segoe Fluent Icons (Windows 11) and Segoe MDL2 Assets (Windows 10) share these code points.
        public const string Moon = "\uE708", Sun = "\uE706", Stopwatch = "\uE916", Pause = "\uE769", Warning = "\uE7BA",
            Cup = "\uEC32", Clock = "\uE823", Check = "\uE73E", Chevron = "\uE76C", Gear = "\uE713", Gauge = "\uEC4A",
            Puzzle = "\uEA86", Done = "\uE930", Dashed = "\uE9F3", Info = "\uE946", Document = "\uE7C3", Refresh = "\uE72C",
            Folder = "\uE8B7", Battery = "\uEBA8", Laptop = "\uE7F8", Power = "\uE7E8", Sync = "\uE895", Link = "\uE71B",
            Activity = "\uE9D9", Layers = "\uE81E", History = "\uE81C", Key = "\uE8D7", Plus = "\uE710", Minus = "\uE738";

        public static float Scale = 1;
        public static Palette App = Palette.Build(false, Color.FromArgb(0x00, 0x5F, 0xB8));
        public static Palette Shell = App;
        public static string IconFont = "Segoe MDL2 Assets";
        public static Font Body, Small, Strong, Heading, Title, Headline, MenuFont, MenuStrong, MenuSmall;
        public static bool RoundedWindows;
        static string textFont = "Yu Gothic UI", strongFont;
        static readonly Dictionary<string, Font> glyphFonts = new Dictionary<string, Font>();
        static readonly Dictionary<string, PointF> inkOffsets = new Dictionary<string, PointF>();
        static readonly Dictionary<string, Bitmap> images = new Dictionary<string, Bitmap>();

        public static int Px(double value) { return (int)Math.Round(value * Scale); }

        /// Real pixels instead of Windows scaling a 96 dpi bitmap, so text stays sharp at 125 % and up.
        public static void EnableDpi()
        {
            try { SetProcessDPIAware(); } catch { }
        }

        static string loaded;

        /// Reads light or dark mode and the accent colour; fonts are made once. Returns false, and
        /// allocates nothing, when the look is unchanged since the last call.
        public static bool Load()
        {
            const string personalize = "HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
            bool appDark = ReadFlag(personalize, "AppsUseLightTheme") == 0;
            bool shellDark = ReadFlag(personalize, "SystemUsesLightTheme") == 0;
            Color appAccent = AccentFor(appDark), shellAccent = AccentFor(shellDark);
            bool contrast = SystemInformation.HighContrast;
            string inputs = appDark + "/" + shellDark + "/" + appAccent.ToArgb() + "/" + shellAccent.ToArgb() + "/" + contrast
                + (contrast ? "/" + SystemColors.Window.ToArgb() + "/" + SystemColors.WindowText.ToArgb() + "/" + SystemColors.Highlight.ToArgb() : "");
            if (inputs == loaded) return false;
            loaded = inputs;
            App = contrast ? Palette.HighContrast() : Palette.Build(appDark, appAccent);
            Shell = contrast ? App : Palette.Build(shellDark, shellAccent);
            images.Clear();
            if (Body != null) return true;

            // The process is system DPI aware, so the scale is fixed for its lifetime.
            using (var g = Graphics.FromHwnd(IntPtr.Zero)) Scale = Math.Max(1f, g.DpiX / 96f);
            var families = new HashSet<string>();
            using (var installed = new InstalledFontCollection())
                foreach (var family in installed.Families) families.Add(family.Name);
            IconFont = families.Contains("Segoe Fluent Icons") ? "Segoe Fluent Icons" : "Segoe MDL2 Assets";
            textFont = families.Contains("Yu Gothic UI") ? "Yu Gothic UI" : SystemFonts.MessageBoxFont.Name;
            strongFont = families.Contains(textFont + " Semibold") ? textFont + " Semibold" : null;
            Body = MakeFont(10f, false); Small = MakeFont(9f, false); Strong = MakeFont(10f, true);
            Heading = MakeFont(10.5f, true); Title = MakeFont(20f, true); Headline = MakeFont(12f, true);
            MenuFont = MakeFont(9.5f, false); MenuStrong = MakeFont(9.5f, true); MenuSmall = MakeFont(8.5f, false);
            return true;
        }

        /// Light or dark regardless of the system setting, for render-settings and render-menu.
        public static void Force(bool dark)
        {
            App = Palette.Build(dark, AccentFor(dark));
            Shell = App;
            images.Clear();
        }

        static int ReadFlag(string key, string name)
        {
            try
            {
                object value = Registry.GetValue(key, name, 1);
                return value is int ? (int)value : 1;
            }
            catch { return 1; }
        }

        /// The accent shade Windows 11 itself uses for controls: darker on light, lighter on dark.
        static Color AccentFor(bool dark)
        {
            try
            {
                var palette = Registry.GetValue("HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Accent", "AccentPalette", null) as byte[];
                if (palette != null && palette.Length >= 32)
                {
                    int i = (dark ? 1 : 4) * 4;
                    return Color.FromArgb(palette[i], palette[i + 1], palette[i + 2]);
                }
            }
            catch { }
            return dark ? Color.FromArgb(0x60, 0xCD, 0xFF) : Color.FromArgb(0x00, 0x5F, 0xB8);
        }

        static Font MakeFont(float size, bool strong)
        {
            if (!strong) return new Font(textFont, size);
            return strongFont != null ? new Font(strongFont, size) : new Font(textFont, size, FontStyle.Bold);
        }

        /// The icon font at a pixel size.
        public static Font Glyph(float pixels)
        {
            string key = IconFont + pixels;
            Font font;
            if (!glyphFonts.TryGetValue(key, out font))
            {
                font = new Font(IconFont, pixels, FontStyle.Regular, GraphicsUnit.Pixel);
                glyphFonts[key] = font;
            }
            return font;
        }

        /// Draws a glyph with its visible shape centred in the area.
        public static void DrawGlyph(Graphics g, string glyph, float pixels, Color color, RectangleF area)
        {
            PointF shift = InkOffset(glyph, pixels);
            area.Offset(shift);
            DrawGlyphBox(g, glyph, pixels, color, area);
        }

        /// The font centres the glyph's em box, not its shape, which leaves most icons up to a couple
        /// of pixels off. This measures how far the drawn shape is from the centre, once per glyph and size.
        static PointF InkOffset(string glyph, float pixels)
        {
            string key = IconFont + "/" + glyph + "/" + pixels;
            PointF shift;
            if (inkOffsets.TryGetValue(key, out shift)) return shift;
            int box = (int)Math.Ceiling(pixels * 2) + 8;
            int minX = box, minY = box, maxX = -1, maxY = -1;
            using (var bitmap = new Bitmap(box, box))
            {
                using (var g = Graphics.FromImage(bitmap))
                {
                    g.Clear(Color.Transparent);
                    DrawGlyphBox(g, glyph, pixels, Color.Black, new RectangleF(0, 0, box, box));
                }
                for (int y = 0; y < box; y++)
                    for (int x = 0; x < box; x++)
                        if (bitmap.GetPixel(x, y).A > 48)
                        {
                            if (x < minX) minX = x;
                            if (x > maxX) maxX = x;
                            if (y < minY) minY = y;
                            if (y > maxY) maxY = y;
                        }
            }
            shift = maxX < 0 ? PointF.Empty : new PointF(box / 2f - (minX + maxX + 1) / 2f, box / 2f - (minY + maxY + 1) / 2f);
            inkOffsets[key] = shift;
            return shift;
        }

        static void DrawGlyphBox(Graphics g, string glyph, float pixels, Color color, RectangleF area)
        {
            var hint = g.TextRenderingHint;
            g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
            using (var brush = new SolidBrush(color))
            using (var format = new StringFormat(StringFormat.GenericTypographic))
            {
                format.Alignment = StringAlignment.Center;
                format.LineAlignment = StringAlignment.Center;
                // The icon font's line is taller than the glyph. GenericTypographic's LineLimit would
                // drop the whole line when the box is only as tall as the font size (menu images, the
                // tray icon), so it is left out.
                format.FormatFlags = StringFormatFlags.FitBlackBox | StringFormatFlags.NoClip | StringFormatFlags.NoWrap;
                g.DrawString(glyph, Glyph(pixels), brush, area, format);
            }
            g.TextRenderingHint = hint;
        }

        /// A glyph or a dot as a menu image, drawn at the menu's own size.
        public static Bitmap GlyphImage(string glyph, Color color, int size)
        {
            string key = glyph + "/" + color.ToArgb() + "/" + size;
            Bitmap image;
            if (images.TryGetValue(key, out image)) return image;
            image = new Bitmap(size, size);
            using (var g = Graphics.FromImage(image))
            {
                g.Clear(Color.Transparent);
                g.SmoothingMode = SmoothingMode.AntiAlias;
                if (glyph == null)
                {
                    float d = size * 0.5f;
                    using (var brush = new SolidBrush(color)) g.FillEllipse(brush, (size - d) / 2, (size - d) / 2, d, d);
                }
                else DrawGlyph(g, glyph, size * 0.85f, color, new RectangleF(0, 0, size, size));
            }
            images[key] = image;
            return image;
        }

        /// A tray or window icon from a glyph. The caller destroys it with FreeIcon.
        public static Icon MakeIcon(string glyph, Color color, int size, Color? badge)
        {
            using (var bitmap = new Bitmap(size, size))
            {
                using (var g = Graphics.FromImage(bitmap))
                {
                    g.Clear(Color.Transparent);
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    if (badge != null)
                    {
                        using (var path = Rounded(new Rectangle(0, 0, size - 1, size - 1), size / 4))
                        using (var brush = new SolidBrush(badge.Value)) g.FillPath(brush, path);
                        DrawGlyph(g, glyph, size * 0.62f, color, new RectangleF(0, 0, size, size));
                    }
                    else DrawGlyph(g, glyph, size, color, new RectangleF(0, 0, size, size));
                }
                return Icon.FromHandle(bitmap.GetHicon());
            }
        }

        public static void FreeIcon(Icon icon)
        {
            if (icon == null) return;
            IntPtr handle = icon.Handle;
            icon.Dispose();
            DestroyIcon(handle);
        }

        public static GraphicsPath Rounded(Rectangle r, int radius)
        {
            var path = new GraphicsPath();
            int d = Math.Max(1, Math.Min(radius * 2, Math.Min(r.Width, r.Height)));
            path.AddArc(r.X, r.Y, d, d, 180, 90);
            path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            path.CloseFigure();
            return path;
        }

        public static void FillRounded(Graphics g, Rectangle r, int radius, Color fill, Color? border)
        {
            var mode = g.SmoothingMode;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            using (var path = Rounded(r, radius))
            {
                using (var brush = new SolidBrush(fill)) g.FillPath(brush, path);
                if (border != null) using (var pen = new Pen(border.Value)) g.DrawPath(pen, path);
            }
            g.SmoothingMode = mode;
        }

        /// Dark title bar to match a dark window (Windows 10 2004 and later).
        public static void StyleTitleBar(IntPtr handle, bool dark)
        {
            int on = dark ? 1 : 0;
            if (DwmSetWindowAttribute(handle, 20, ref on, 4) != 0) DwmSetWindowAttribute(handle, 19, ref on, 4);
        }

        /// Windows 11 rounded corners for menus; Windows 10 ignores it and the renderer draws a border.
        public static void RoundCorners(IntPtr handle)
        {
            int round = 2;
            try { RoundedWindows = DwmSetWindowAttribute(handle, 33, ref round, 4) == 0; } catch { RoundedWindows = false; }
        }

        public static int TextHeight(string text, Font font, int width)
        {
            if (string.IsNullOrEmpty(text)) return 0;
            return TextRenderer.MeasureText(text, font, new Size(Math.Max(1, width), int.MaxValue),
                TextFormatFlags.WordBreak | TextFormatFlags.NoPadding | TextFormatFlags.TextBoxControl).Height;
        }

        public static void DrawText(Graphics g, string text, Font font, Rectangle area, Color color, TextFormatFlags flags)
        {
            TextRenderer.DrawText(g, text, font, area, color, flags | TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix);
        }
    }

    // ---------------------------------------------------------------- tray menu

    /// Item kinds the renderer draws differently; set as a menu item's Tag.
    static class MenuTag
    {
        public const string Header = "header", Detail = "detail", Session = "session";
    }

    /// Windows 11 style menu: flat surface, rounded hover, glyph checks and chevrons, light or dark
    /// following the taskbar.
    class MenuRenderer : ToolStripRenderer
    {
        static Palette P { get { return Theme.Shell; } }

        protected override void OnRenderToolStripBackground(ToolStripRenderEventArgs e)
        {
            using (var brush = new SolidBrush(P.Menu)) e.Graphics.FillRectangle(brush, e.AffectedBounds);
        }

        protected override void OnRenderToolStripBorder(ToolStripRenderEventArgs e)
        {
            var r = new Rectangle(0, 0, e.ToolStrip.Width - 1, e.ToolStrip.Height - 1);
            using (var pen = new Pen(P.MenuBorder)) e.Graphics.DrawRectangle(pen, r);
        }

        protected override void OnRenderImageMargin(ToolStripRenderEventArgs e) { }

        protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e)
        {
            var item = e.Item as ToolStripMenuItem;
            if (item == null || !item.Enabled || !(item.Selected || item.Pressed)) return;
            var r = new Rectangle(Theme.Px(4), 1, e.Item.Width - Theme.Px(8), e.Item.Height - 2);
            Theme.FillRounded(e.Graphics, r, Theme.Px(4), P.MenuHover, null);
        }

        protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e)
        {
            // Drawn here rather than by the base class, which greys every disabled item; the
            // headline and the sessions are disabled only so they can't be clicked.
            string tag = e.Item.Tag as string;
            Color color;
            if (e.Text != e.Item.Text) color = P.SubText; // the right-hand column
            else if (tag == MenuTag.Detail) color = P.SubText;
            else if (tag == MenuTag.Header || tag == MenuTag.Session || e.Item.Enabled) color = P.Text;
            else color = P.Disabled;
            // In a contrast theme the hover fill is the highlight colour, so the text takes its pair.
            if (SystemInformation.HighContrast && e.Item.Enabled && e.Item.Selected) color = P.OnAccent;
            TextRenderer.DrawText(e.Graphics, e.Text, e.TextFont, e.TextRectangle, color, e.TextFormat | TextFormatFlags.NoPrefix);
        }

        protected override void OnRenderItemImage(ToolStripItemImageRenderEventArgs e)
        {
            // Raised like the check marks, to line up with the text.
            if (e.Image != null) e.Graphics.DrawImage(e.Image, new Rectangle(e.ImageRectangle.X, e.ImageRectangle.Y - Theme.Px(3), e.ImageRectangle.Width, e.ImageRectangle.Height));
        }

        protected override void OnRenderItemCheck(ToolStripItemImageRenderEventArgs e)
        {
            Color color = e.Item.Enabled ? P.Text : P.Disabled;
            // Lined up with the text, which sits about 3 px (at 100 %) above the middle of the row.
            var r = e.ImageRectangle;
            Theme.DrawGlyph(e.Graphics, Theme.Check, Theme.Px(12), color, new RectangleF(r.X, -Theme.Px(3), r.Width, e.Item.Height));
        }

        protected override void OnRenderArrow(ToolStripArrowRenderEventArgs e)
        {
            var r = e.ArrowRectangle;
            Theme.DrawGlyph(e.Graphics, Theme.Chevron, Theme.Px(10), e.Item.Enabled ? P.SubText : P.Disabled, new RectangleF(r.X, -Theme.Px(3), r.Width, e.Item.Height));
        }

        protected override void OnRenderSeparator(ToolStripSeparatorRenderEventArgs e)
        {
            int y = e.Item.Height / 2;
            using (var pen = new Pen(P.Separator)) e.Graphics.DrawLine(pen, Theme.Px(12), y, e.Item.Width - Theme.Px(12), y);
        }

        /// Gives a menu (or submenu) this look: renderer, sizes, and rounded corners once it has a window.
        public static void Apply(ToolStripDropDown menu)
        {
            menu.Renderer = new MenuRenderer();
            menu.Font = Theme.MenuFont;
            menu.ImageScalingSize = new Size(Theme.Px(16), Theme.Px(16));
            menu.Padding = new Padding(0, Theme.Px(4), 0, Theme.Px(4));
            menu.DropShadowEnabled = true;
            if (menu.IsHandleCreated) Theme.RoundCorners(menu.Handle);
            else menu.HandleCreated += delegate { Theme.RoundCorners(menu.Handle); };
        }
    }

    // ---------------------------------------------------------------- controls

    /// Something the vertical Stack sizes to its width.
    interface IStackItem
    {
        int HeightFor(int width);
        /// Space above this item in the stack.
        int GapBefore { get; }
        bool Collapsed { get; }
    }

    /// A vertical, scrolling column of cards, headings and notes, each as wide as the column.
    class Stack : Panel
    {
        int laidOutHeight = -1;

        public Stack()
        {
            AutoScroll = true;
            DoubleBuffered = true;
            BackColor = Theme.App.Window;
            Padding = new Padding(Theme.Px(4), Theme.Px(4), Theme.Px(28), Theme.Px(24));
        }

        protected override void OnLayout(LayoutEventArgs e)
        {
            int width = ClientSize.Width - Padding.Horizontal;
            int y = Padding.Top;
            bool first = true;
            foreach (Control c in Controls)
            {
                var item = c as IStackItem;
                if (item != null && item.Collapsed) { c.Bounds = new Rectangle(0, 0, 0, 0); continue; }
                if (!first && item != null) y += item.GapBefore;
                int h = item != null ? item.HeightFor(width) : c.Height;
                c.Bounds = new Rectangle(Padding.Left, y + AutoScrollPosition.Y, width, h);
                y += h;
                first = false;
            }
            y += Padding.Bottom;
            if (y != laidOutHeight)
            {
                laidOutHeight = y;
                AutoScrollMinSize = new Size(0, y);
            }
            // Shows or hides the scrollbar; a change of client width lays the column out again.
            base.OnLayout(e);
        }

        protected override void OnResize(EventArgs e)
        {
            base.OnResize(e);
            PerformLayout();
        }

        [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)] static extern int SetWindowTheme(IntPtr hwnd, string app, string idList);

        /// Dark scrollbars in a dark window (the theme Explorer itself uses).
        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            if (Theme.App.Dark) { try { SetWindowTheme(Handle, "DarkMode_Explorer", null); } catch { } }
        }
    }

    /// A section heading above a group of cards.
    class SectionLabel : Control, IStackItem
    {
        public SectionLabel(string text)
        {
            Text = text;
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            BackColor = Theme.App.Window;
        }

        public int HeightFor(int width) { return Theme.TextHeight(Text, Theme.Heading, width) + Theme.Px(10); }
        public int GapBefore { get { return Theme.Px(22); } }
        public bool Collapsed { get { return false; } }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.Clear(BackColor);
            Theme.DrawText(e.Graphics, Text, Theme.Heading, new Rectangle(Theme.Px(2), 0, Width, Height - Theme.Px(6)), Theme.App.Text,
                TextFormatFlags.Bottom | TextFormatFlags.Left | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
        }
    }

    /// Grey explanatory text under a group of cards.
    class NoteLabel : Control, IStackItem
    {
        public NoteLabel(string text)
        {
            Text = text;
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            BackColor = Theme.App.Window;
        }

        public int HeightFor(int width) { return Theme.TextHeight(Text, Theme.Small, width - Theme.Px(4)) + Theme.Px(4); }
        public int GapBefore { get { return Theme.Px(8); } }
        public bool Collapsed { get { return string.IsNullOrEmpty(Text); } }

        protected override void OnTextChanged(EventArgs e)
        {
            base.OnTextChanged(e);
            if (Parent != null) Parent.PerformLayout();
            Invalidate();
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.Clear(BackColor);
            Theme.DrawText(e.Graphics, Text, Theme.Small, new Rectangle(Theme.Px(2), Theme.Px(2), Width - Theme.Px(4), Height), Theme.App.SubText,
                TextFormatFlags.WordBreak | TextFormatFlags.TextBoxControl);
        }
    }

    /// A Windows 11 settings card: an icon, a title, a description, and a control on the right.
    /// Clicking the text of a card with a switch flips the switch.
    class SettingCard : Panel, IStackItem
    {
        string title, description, glyph;
        Color? glyphColor;
        readonly Control control;
        public bool Hidden;
        public bool Joined;

        public SettingCard(string title, string description, string glyph, Control control)
        {
            this.title = title;
            this.description = description;
            this.glyph = glyph;
            this.control = control;
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            BackColor = Theme.App.Card;
            if (control != null)
            {
                control.BackColor = Theme.App.Card;
                if (string.IsNullOrEmpty(control.AccessibleName)) control.AccessibleName = title;
                if (string.IsNullOrEmpty(control.AccessibleDescription)) control.AccessibleDescription = description;
                Controls.Add(control);
                var toggle = control as CheckBox;
                if (toggle != null)
                {
                    Cursor = Cursors.Hand;
                    Click += delegate { if (toggle.Enabled) { toggle.Checked = !toggle.Checked; toggle.Focus(); } };
                }
            }
        }

        public string Title { get { return title; } set { if (value != title) { title = value; Relayout(); } } }
        public string Description { get { return description; } set { if (value != description) { description = value; if (control != null) control.AccessibleDescription = value; Relayout(); } } }
        public void SetGlyph(string value, Color? color) { glyph = value; glyphColor = color; Invalidate(); }

        void Relayout()
        {
            if (Parent != null) Parent.PerformLayout();
            Invalidate();
        }

        int PadX { get { return Theme.Px(16); } }
        int PadY { get { return Theme.Px(13); } }
        int TextLeft { get { return glyph != null ? Theme.Px(56) : PadX; } }
        int TextRight(int width) { return width - PadX - (control != null ? control.Width + Theme.Px(16) : 0); }

        public int GapBefore { get { return Joined ? Theme.Px(1) : Theme.Px(4); } }
        public bool Collapsed { get { return Hidden; } }

        public int HeightFor(int width)
        {
            int textWidth = TextRight(width) - TextLeft;
            int text = Theme.TextHeight(title, Theme.Body, textWidth);
            if (!string.IsNullOrEmpty(description)) text += Theme.Px(2) + Theme.TextHeight(description, Theme.Small, textWidth);
            int inner = Math.Max(text, control != null ? control.Height : 0);
            return Math.Max(Theme.Px(62), inner + PadY * 2);
        }

        protected override void OnLayout(LayoutEventArgs e)
        {
            if (control != null)
                control.Location = new Point(Width - PadX - control.Width, (Height - control.Height) / 2);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            var p = Theme.App;
            var g = e.Graphics;
            g.Clear(Parent != null ? Parent.BackColor : p.Window);
            Theme.FillRounded(g, new Rectangle(0, 0, Width - 1, Height - 1), Theme.Px(6), p.Card, p.CardBorder);
            if (glyph != null)
                Theme.DrawGlyph(g, glyph, Theme.Px(18), glyphColor ?? p.Text, new RectangleF(PadX, 0, Theme.Px(24), Height));
            int left = TextLeft, width = TextRight(Width) - left;
            int titleHeight = Theme.TextHeight(title, Theme.Body, width);
            int descHeight = string.IsNullOrEmpty(description) ? 0 : Theme.Px(2) + Theme.TextHeight(description, Theme.Small, width);
            int top = (Height - titleHeight - descHeight) / 2;
            var flags = TextFormatFlags.WordBreak | TextFormatFlags.TextBoxControl;
            Theme.DrawText(g, title, Theme.Body, new Rectangle(left, top, width, titleHeight), p.Text, flags);
            if (descHeight > 0)
                Theme.DrawText(g, description, Theme.Small, new Rectangle(left, top + titleHeight + Theme.Px(2), width, descHeight), p.SubText, flags);
        }
    }

    /// The current state at the top of the General page: the tray icon's glyph, the headline and details.
    class StatusCard : Control, IStackItem
    {
        string glyph = Theme.Moon, headline = "", details = "";
        bool warn;

        public StatusCard()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            BackColor = Theme.App.Window;
            AccessibleRole = AccessibleRole.StaticText;
        }

        public void SetState(string glyph, bool warn, string headline, string details)
        {
            if (glyph == this.glyph && warn == this.warn && headline == this.headline && details == this.details) return;
            bool resize = details != this.details || headline != this.headline;
            this.glyph = glyph; this.warn = warn; this.headline = headline; this.details = details;
            AccessibleName = headline;
            AccessibleDescription = details;
            if (resize && Parent != null) Parent.PerformLayout();
            Invalidate();
        }

        int TextLeft { get { return Theme.Px(92); } }

        public int HeightFor(int width)
        {
            int w = width - TextLeft - Theme.Px(20);
            int text = Theme.TextHeight(headline, Theme.Headline, w) + Theme.Px(4) + Theme.TextHeight(details, Theme.Small, w);
            return Math.Max(Theme.Px(96), text + Theme.Px(40));
        }

        public int GapBefore { get { return 0; } }
        public bool Collapsed { get { return false; } }

        protected override void OnPaint(PaintEventArgs e)
        {
            var p = Theme.App;
            var g = e.Graphics;
            g.Clear(BackColor);
            Theme.FillRounded(g, new Rectangle(0, 0, Width - 1, Height - 1), Theme.Px(8), p.Card, p.CardBorder);
            int size = Theme.Px(56);
            var badge = new Rectangle(Theme.Px(20), (Height - size) / 2, size, size);
            Color tone = warn ? p.Warn : p.Accent;
            Theme.FillRounded(g, badge, Theme.Px(12), Palette.Blend(p.Card, tone, p.Dark ? 0.22 : 0.12), null);
            Theme.DrawGlyph(g, glyph, Theme.Px(26), tone, badge);
            int w = Width - TextLeft - Theme.Px(20);
            int h1 = Theme.TextHeight(headline, Theme.Headline, w);
            int h2 = Theme.TextHeight(details, Theme.Small, w);
            int top = (Height - h1 - Theme.Px(4) - h2) / 2;
            var flags = TextFormatFlags.WordBreak | TextFormatFlags.TextBoxControl;
            Theme.DrawText(g, headline, Theme.Headline, new Rectangle(TextLeft, top, w, h1), p.Text, flags);
            Theme.DrawText(g, details, Theme.Small, new Rectangle(TextLeft, top + h1 + Theme.Px(4), w, h2), p.SubText, flags);
        }
    }

    /// A row of buttons in the stack.
    class ButtonRow : FlowLayoutPanel, IStackItem
    {
        public ButtonRow(params Control[] buttons)
        {
            FlowDirection = FlowDirection.LeftToRight;
            WrapContents = true;
            BackColor = Theme.App.Window;
            Padding = new Padding(0);
            foreach (var b in buttons) { b.Margin = new Padding(0, 0, Theme.Px(8), Theme.Px(8)); Controls.Add(b); }
        }

        public int HeightFor(int width) { return Theme.Px(40); }
        public int GapBefore { get { return Theme.Px(16); } }
        public bool Collapsed { get { return false; } }
    }

    /// The Windows 11 toggle switch, with "オン" or "オフ" beside it. Still a CheckBox, so Space,
    /// Checked and CheckedChanged work as before.
    class ToggleSwitch : CheckBox
    {
        bool hover, down;

        public ToggleSwitch()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            AutoSize = false;
            Text = "";
            Size = new Size(Theme.Px(92), Theme.Px(32));
            Cursor = Cursors.Hand;
        }

        protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hover = false; down = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnMouseDown(MouseEventArgs e) { down = true; Invalidate(); base.OnMouseDown(e); }
        protected override void OnMouseUp(MouseEventArgs e) { down = false; Invalidate(); base.OnMouseUp(e); }
        protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }
        protected override void OnCheckedChanged(EventArgs e) { Invalidate(); base.OnCheckedChanged(e); }

        protected override void OnPaint(PaintEventArgs e)
        {
            var p = Theme.App;
            var g = e.Graphics;
            g.Clear(BackColor);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            int w = Theme.Px(40), h = Theme.Px(20);
            var track = new Rectangle(Width - w - Theme.Px(3), (Height - h) / 2, w, h);
            Theme.DrawText(g, Checked ? "オン" : "オフ", Theme.Body, new Rectangle(0, 0, track.Left - Theme.Px(12), Height),
                Enabled ? p.Text : p.Disabled, TextFormatFlags.Right | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
            if (Checked)
            {
                Color fill = !Enabled ? p.Disabled : down ? p.AccentPressed : hover ? p.AccentHover : p.Accent;
                Theme.FillRounded(g, track, h / 2, fill, null);
            }
            else
            {
                Color fill = hover && Enabled ? p.ControlHover : p.Card;
                Theme.FillRounded(g, new Rectangle(track.X, track.Y, track.Width - 1, track.Height - 1), h / 2, fill, Enabled ? p.SubText : p.Disabled);
            }
            float knob = Theme.Px(down && Enabled ? 14 : hover && Enabled ? 14 : 12) - (Checked ? 0 : Theme.Px(2));
            float cx = Checked ? track.Right - h / 2f : track.Left + h / 2f;
            float cy = track.Top + h / 2f;
            Color knobColor = Checked ? (Enabled ? p.OnAccent : p.Card) : (Enabled ? p.SubText : p.Disabled);
            using (var brush = new SolidBrush(knobColor)) g.FillEllipse(brush, cx - knob / 2, cy - knob / 2, knob, knob);
            if (Focused && ShowFocusCues)
            {
                var ring = Rectangle.Inflate(track, Theme.Px(3), Theme.Px(3));
                using (var path = Theme.Rounded(ring, ring.Height / 2))
                using (var pen = new Pen(p.Text, Math.Max(1.5f, Theme.Scale * 1.5f))) g.DrawPath(pen, path);
            }
        }
    }

    /// Windows 11 buttons: an accent button for the main action, a quiet one for the rest.
    class FlatButton : Button
    {
        bool hover, down;
        public bool Primary;
        public string Glyph;

        public FlatButton(string text, bool primary = false, string glyph = null)
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            Text = text;
            Primary = primary;
            Glyph = glyph;
            Font = Theme.Body;
            int textWidth = TextRenderer.MeasureText(text, Theme.Body).Width;
            Size = new Size(Math.Max(Theme.Px(96), textWidth + Theme.Px(glyph != null ? 52 : 32)), Theme.Px(32));
        }

        protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hover = false; down = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnMouseDown(MouseEventArgs e) { down = true; Invalidate(); base.OnMouseDown(e); }
        protected override void OnMouseUp(MouseEventArgs e) { down = false; Invalidate(); base.OnMouseUp(e); }
        protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }

        protected override void OnPaint(PaintEventArgs e)
        {
            var p = Theme.App;
            var g = e.Graphics;
            g.Clear(Parent != null ? Parent.BackColor : p.Window);
            var r = new Rectangle(0, 0, Width - 1, Height - 1);
            Color fill, text, border;
            if (Primary && Enabled)
            {
                fill = down ? p.AccentPressed : hover ? p.AccentHover : p.Accent;
                text = p.OnAccent; border = fill;
            }
            else
            {
                fill = !Enabled ? p.Card : down ? p.ControlPressed : hover ? p.ControlHover : p.Control;
                text = Enabled ? p.Text : p.Disabled; border = p.ControlBorder;
            }
            Theme.FillRounded(g, r, Theme.Px(4), fill, border);
            var area = new Rectangle(0, 0, Width, Height);
            if (Glyph != null)
            {
                int textWidth = TextRenderer.MeasureText(Text, Font).Width;
                int total = Theme.Px(16) + Theme.Px(8) + textWidth;
                int left = (Width - total) / 2;
                Theme.DrawGlyph(g, Glyph, Theme.Px(14), text, new RectangleF(left, 0, Theme.Px(16), Height));
                area = new Rectangle(left + Theme.Px(24), 0, textWidth + Theme.Px(2), Height);
                Theme.DrawText(g, Text, Font, area, text, TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
            }
            else Theme.DrawText(g, Text, Font, area, text, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
            if (Focused && ShowFocusCues)
            {
                using (var path = Theme.Rounded(Rectangle.Inflate(r, -Theme.Px(2), -Theme.Px(2)), Theme.Px(3)))
                using (var pen = new Pen(Primary ? p.OnAccent : p.Text, Math.Max(1f, Theme.Scale))) g.DrawPath(pen, path);
            }
        }
    }

    /// A number with − and + buttons, the value and its unit between them. Arrow keys, Page Up and
    /// Down, Home, End and the mouse wheel change it too.
    class Stepper : Control
    {
        decimal value, minimum, maximum = 100, increment = 1;
        int hoverZone = -1, downZone = -1;
        public string Unit = "";
        public Func<decimal, string> Format;
        public event EventHandler ValueChanged;

        public Stepper()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer
                | ControlStyles.ResizeRedraw | ControlStyles.Selectable, true);
            TabStop = true;
            Size = new Size(Theme.Px(156), Theme.Px(32));
            AccessibleRole = AccessibleRole.SpinButton;
        }

        // The limits clamp the value quietly: they are set up in code, not changed by the user.
        public decimal Minimum { get { return minimum; } set { minimum = value; this.value = Math.Max(minimum, Math.Min(maximum, this.value)); Invalidate(); } }
        public decimal Maximum { get { return maximum; } set { maximum = value; this.value = Math.Max(minimum, Math.Min(maximum, this.value)); Invalidate(); } }
        public decimal Increment { get { return increment; } set { increment = value; } }

        public decimal Value
        {
            get { return value; }
            set
            {
                decimal v = Math.Max(minimum, Math.Min(maximum, value));
                if (v == this.value) return;
                this.value = v;
                changedAt = Environment.TickCount;
                Invalidate();
                AccessibilityNotifyClients(AccessibleEvents.ValueChange, -1);
                if (ValueChanged != null) ValueChanged(this, EventArgs.Empty);
            }
        }

        /// When this control last changed its value itself (Environment.TickCount), 0 if never.
        int changedAt;

        /// Sets the value from text, as typing, pasting or a screen reader would; false if it isn't a number.
        public bool SetFromText(string text)
        {
            decimal number;
            string digits = (text ?? "").Trim();
            if (digits.Length == 0 || digits.Length > 6 ||
                !decimal.TryParse(digits, System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out number))
                return false;
            typed = null;
            Value = number;
            Invalidate();
            return true;
        }

        /// Digits typed while focused; Enter or leaving the control applies them, Esc cancels.
        string typed;

        public string DisplayText
        {
            get
            {
                if (typed != null) return typed + " " + Unit;
                return Format != null ? Format(value) : value.ToString("0.##") + " " + Unit;
            }
        }

        /// Steps from the typed number if there is one, setting Value (and so saving) only once.
        void Step(int direction)
        {
            decimal start = value;
            if (typed != null)
            {
                decimal number;
                if (typed.Length > 0 && decimal.TryParse(typed, System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out number))
                    start = Math.Max(minimum, Math.Min(maximum, number));
                typed = null;
                Invalidate();
            }
            Value = start + direction * increment;
        }

        /// Sets the value from outside without dropping digits being typed.
        public void Sync(decimal v)
        {
            // A status sent before the watcher saw this control's last change would undo it, and the
            // next step would start from the old value. Changes made here win for a moment.
            if (changedAt != 0 && unchecked(Environment.TickCount - changedAt) < 2000) return;
            decimal clamped = Math.Max(minimum, Math.Min(maximum, v));
            if (clamped == value) return;
            value = clamped;
            Invalidate();
        }

        void DiscardTyped()
        {
            if (typed == null) return;
            typed = null;
            Invalidate();
        }

        void CommitTyped()
        {
            if (typed == null) return;
            string text = typed;
            typed = null;
            decimal number;
            if (text.Length > 0 && decimal.TryParse(text, System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out number))
                Value = number;
            Invalidate();
        }

        Rectangle MinusZone { get { return new Rectangle(0, 0, Height, Height); } }
        Rectangle PlusZone { get { return new Rectangle(Width - Height, 0, Height, Height); } }

        int ZoneAt(Point point)
        {
            if (MinusZone.Contains(point)) return 0;
            if (PlusZone.Contains(point)) return 1;
            return -1;
        }

        protected override void OnMouseMove(MouseEventArgs e) { int z = ZoneAt(e.Location); if (z != hoverZone) { hoverZone = z; Invalidate(); } base.OnMouseMove(e); }
        protected override void OnMouseLeave(EventArgs e) { hoverZone = -1; downZone = -1; Invalidate(); base.OnMouseLeave(e); }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            Focus();
            if (e.Button == MouseButtons.Left) downZone = ZoneAt(e.Location);
            Invalidate();
            base.OnMouseDown(e);
        }

        /// A button acts on release over itself, so dragging away cancels, like any button.
        protected override void OnMouseUp(MouseEventArgs e)
        {
            if (e.Button == MouseButtons.Left && downZone >= 0 && ZoneAt(e.Location) == downZone) Step(downZone == 0 ? -1 : 1);
            downZone = -1;
            Invalidate();
            base.OnMouseUp(e);
        }

        protected override void OnMouseWheel(MouseEventArgs e)
        {
            if (Focused) Step(e.Delta > 0 ? 1 : -1);
            base.OnMouseWheel(e);
        }

        protected override bool IsInputKey(Keys keyData)
        {
            switch (keyData)
            {
                case Keys.Up: case Keys.Down: case Keys.Left: case Keys.Right: return true;
            }
            return base.IsInputKey(keyData);
        }

        protected override void OnKeyPress(KeyPressEventArgs e)
        {
            if (e.KeyChar >= '0' && e.KeyChar <= '9')
            {
                if (typed == null || typed.Length < 6) typed = (typed ?? "") + e.KeyChar;
                e.Handled = true;
                Invalidate();
            }
            else if (e.KeyChar == '\b' && typed != null)
            {
                typed = typed.Length > 1 ? typed.Substring(0, typed.Length - 1) : "";
                e.Handled = true;
                Invalidate();
            }
            base.OnKeyPress(e);
        }

        protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
        {
            // Ctrl+V or Shift+Insert: paste a number.
            if (keyData == (Keys.Control | Keys.V) || keyData == (Keys.Shift | Keys.Insert))
            {
                try { if (Clipboard.ContainsText()) SetFromText(Clipboard.GetText()); } catch { }
                return true;
            }
            return base.ProcessCmdKey(ref msg, keyData);
        }

        protected override bool ProcessDialogKey(Keys keyData)
        {
            // Enter and Esc finish typing instead of pressing the window's default buttons.
            if (typed != null && keyData == Keys.Enter) { CommitTyped(); return true; }
            if (typed != null && keyData == Keys.Escape) { typed = null; Invalidate(); return true; }
            return base.ProcessDialogKey(keyData);
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            switch (e.KeyCode)
            {
                case Keys.Up: case Keys.Right: case Keys.Add: case Keys.Oemplus: Step(1); e.Handled = true; break;
                case Keys.Down: case Keys.Left: case Keys.Subtract: case Keys.OemMinus: Step(-1); e.Handled = true; break;
                case Keys.PageUp: DiscardTyped(); Value = value + increment * 5; e.Handled = true; break;
                case Keys.PageDown: DiscardTyped(); Value = value - increment * 5; e.Handled = true; break;
                case Keys.Home: DiscardTyped(); Value = minimum; e.Handled = true; break;
                case Keys.End: DiscardTyped(); Value = maximum; e.Handled = true; break;
            }
            base.OnKeyDown(e);
        }

        protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
        protected override void OnLostFocus(EventArgs e) { CommitTyped(); Invalidate(); base.OnLostFocus(e); }
        protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }

        protected override void OnPaint(PaintEventArgs e)
        {
            var p = Theme.App;
            var g = e.Graphics;
            g.Clear(BackColor);
            var r = new Rectangle(0, 0, Width - 1, Height - 1);
            Theme.FillRounded(g, r, Theme.Px(4), p.Control, Focused ? p.Accent : p.ControlBorder);
            if (Focused)
                using (var pen = new Pen(p.Accent, Math.Max(1f, Theme.Scale))) g.DrawLine(pen, Theme.Px(4), Height - 1, Width - Theme.Px(4), Height - 1);
            for (int zone = 0; zone < 2; zone++)
            {
                var area = zone == 0 ? MinusZone : PlusZone;
                bool atLimit = zone == 0 ? value <= minimum : value >= maximum;
                if (Enabled && !atLimit && (hoverZone == zone || downZone == zone))
                    Theme.FillRounded(g, Rectangle.Inflate(area, -Theme.Px(4), -Theme.Px(4)), Theme.Px(4), downZone == zone ? p.ControlPressed : p.Hover, null);
                Theme.DrawGlyph(g, zone == 0 ? Theme.Minus : Theme.Plus, Theme.Px(12), Enabled && !atLimit ? p.Text : p.Disabled, area);
            }
            Theme.DrawText(g, DisplayText, Theme.Body, new Rectangle(Height, 0, Width - Height * 2, Height), Enabled ? p.Text : p.Disabled,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
        }

        protected override AccessibleObject CreateAccessibilityInstance() { return new StepperAccessible(this); }

        class StepperAccessible : ControlAccessibleObject
        {
            readonly Stepper owner;
            public StepperAccessible(Stepper owner) : base(owner) { this.owner = owner; }
            public override string Value { get { return owner.DisplayText; } set { owner.SetFromText(value); } }
            public override AccessibleRole Role { get { return AccessibleRole.SpinButton; } }
        }
    }

    /// An item in the Settings window's left-hand list of pages.
    class NavButton : Button
    {
        bool hover, selected;
        readonly string glyph;

        public NavButton(string text, string glyph)
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            Text = text;
            this.glyph = glyph;
            Font = Theme.Body;
            Height = Theme.Px(38);
            AccessibleRole = AccessibleRole.PageTab;
        }

        public bool Selected
        {
            get { return selected; }
            set { selected = value; AccessibleDescription = value ? "選択中" : null; Invalidate(); }
        }

        protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hover = false; Invalidate(); base.OnMouseLeave(e); }

        protected override void OnPaint(PaintEventArgs e)
        {
            var p = Theme.App;
            var g = e.Graphics;
            g.Clear(p.Window);
            var r = new Rectangle(0, Theme.Px(2), Width - 1, Height - Theme.Px(4) - 1);
            if (selected || hover) Theme.FillRounded(g, r, Theme.Px(4), selected ? p.Selected : p.Hover, null);
            if (selected)
            {
                int bar = Theme.Px(16);
                Theme.FillRounded(g, new Rectangle(0, (Height - bar) / 2, Theme.Px(3), bar), Theme.Px(2), p.Accent, null);
            }
            Theme.DrawGlyph(g, glyph, Theme.Px(16), p.Text, new RectangleF(Theme.Px(12), 0, Theme.Px(20), Height));
            Theme.DrawText(g, Text, selected ? Theme.Strong : Theme.Body, new Rectangle(Theme.Px(44), 0, Width - Theme.Px(48), Height), p.Text,
                TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
            if (Focused && ShowFocusCues)
                using (var path = Theme.Rounded(r, Theme.Px(4)))
                using (var pen = new Pen(p.Text, Math.Max(1.5f, Theme.Scale * 1.5f))) g.DrawPath(pen, path);
        }
    }

    /// The app's mark and name above the page list.
    class Brand : Control
    {
        public Brand()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            Text = "Agent Lid Closed";
            Height = Theme.Px(64);
            AccessibleRole = AccessibleRole.StaticText;
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            var p = Theme.App;
            var g = e.Graphics;
            g.Clear(p.Window);
            int size = Theme.Px(32);
            var mark = new Rectangle(Theme.Px(8), (Height - size) / 2, size, size);
            Theme.FillRounded(g, mark, Theme.Px(8), p.Accent, null);
            Theme.DrawGlyph(g, Theme.Cup, Theme.Px(18), p.OnAccent, mark);
            Theme.DrawText(g, Text, Theme.Strong, new Rectangle(mark.Right + Theme.Px(12), 0, Width - mark.Right - Theme.Px(12), Height), p.Text,
                TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
        }
    }

    /// The small window that asks how long to keep the computer awake.
    static class InputDialog
    {
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessage(IntPtr hwnd, int message, IntPtr wParam, string lParam);

        public static string Show(string title, string message, string placeholder)
        {
            var p = Theme.App;
            using (var form = new Form())
            {
                form.Text = title;
                form.FormBorderStyle = FormBorderStyle.FixedDialog;
                form.StartPosition = FormStartPosition.CenterScreen;
                form.MinimizeBox = false; form.MaximizeBox = false; form.ShowIcon = false;
                form.BackColor = p.Window;
                form.Font = Theme.Body;
                form.ClientSize = new Size(Theme.Px(440), Theme.Px(212));
                form.TopMost = true;
                form.HandleCreated += delegate { Theme.StyleTitleBar(form.Handle, p.Dark); };
                int pad = Theme.Px(24), width = form.ClientSize.Width - pad * 2;
                var heading = new Label { Text = title, Font = Theme.Headline, ForeColor = p.Text, Left = pad, Top = Theme.Px(18), Width = width, Height = Theme.Px(30) };
                var label = new Label { Text = message, Font = Theme.Small, ForeColor = p.SubText, Left = pad, Top = Theme.Px(50), Width = width };
                label.Height = Theme.TextHeight(message, Theme.Small, width) + Theme.Px(4);
                var box = new TextBox { Left = pad, Width = width, Text = "", Font = Theme.Body, BackColor = p.Dark ? p.Control : Color.White, ForeColor = p.Text, BorderStyle = BorderStyle.FixedSingle };
                box.Top = label.Bottom + Theme.Px(10);
                // EM_SETCUEBANNER: grey example text while the box is empty.
                box.HandleCreated += delegate { SendMessage(box.Handle, 0x1501, new IntPtr(1), placeholder); };
                var ok = new FlatButton("開始", true) { DialogResult = DialogResult.OK };
                var cancel = new FlatButton("キャンセル") { DialogResult = DialogResult.Cancel };
                // The buttons sit on a darker band, like a Windows 11 dialog.
                var band = new Panel { Dock = DockStyle.Bottom, Height = Theme.Px(64), BackColor = p.Dark ? Color.FromArgb(0x1A, 0x1A, 0x1A) : Color.FromArgb(0xEC, 0xEC, 0xEC) };
                cancel.Top = ok.Top = (band.Height - ok.Height) / 2;
                cancel.Left = form.ClientSize.Width - pad - cancel.Width;
                ok.Left = cancel.Left - Theme.Px(8) - ok.Width;
                band.Controls.Add(ok); band.Controls.Add(cancel);
                form.ClientSize = new Size(form.ClientSize.Width, box.Bottom + Theme.Px(24) + band.Height);
                form.Controls.AddRange(new Control[] { heading, label, box, band });
                form.AcceptButton = ok; form.CancelButton = cancel;
                form.ActiveControl = box;
                return form.ShowDialog() == DialogResult.OK ? box.Text : null;
            }
        }
    }
}
