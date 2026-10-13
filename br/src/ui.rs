use dialoguer::console::{Style, Term};
use dialoguer::theme::Theme;
use indicatif::{ProgressBar, ProgressStyle};
use std::fmt;
use std::io::{self, IsTerminal};

#[derive(Clone, Copy)]
pub(crate) enum Tone {
    Accent,
    Value,
    Success,
    Warning,
    Error,
    Muted,
}

pub(crate) fn color_enabled(terminal: bool) -> bool {
    terminal
        && std::env::var_os("TERM").is_none_or(|value| value != "dumb")
        && std::env::var_os("NO_COLOR").is_none_or(|value| value.is_empty())
        && std::env::var_os("CLICOLOR").is_none_or(|value| value != "0")
}

pub(crate) fn paint(text: &str, tone: Tone, color: bool) -> String {
    if !color {
        return text.to_owned();
    }
    let style = match tone {
        Tone::Accent => Style::new().cyan().bold(),
        Tone::Value => Style::new().magenta().bold(),
        Tone::Success => Style::new().green().bold(),
        Tone::Warning => Style::new().yellow().bold(),
        Tone::Error => Style::new().red().bold(),
        Tone::Muted => Style::new().dim(),
    };
    style.force_styling(true).apply_to(text).to_string()
}

pub(crate) fn separator(title: &str, width: usize, color: bool) -> String {
    let label = format!("-- {title} ");
    let bar = "-".repeat(width.saturating_sub(label.len()));
    format!(
        "{}{}",
        paint(&label, Tone::Accent, color),
        paint(&bar, Tone::Muted, color)
    )
}

pub(crate) fn section(title: &str) {
    if !io::stderr().is_terminal() {
        return;
    }
    let width = usize::from(Term::stderr().size().1).min(80);
    eprintln!("\n{}", separator(title, width, color_enabled(true)));
}

pub(crate) fn heading(command: &str) {
    if io::stderr().is_terminal() {
        eprintln!(
            "{} / {command}",
            paint("br", Tone::Value, color_enabled(true))
        );
    }
}

pub(crate) fn detail(label: &str, value: &str) {
    if io::stderr().is_terminal() {
        let color = color_enabled(true);
        eprintln!(
            "   {}  {}",
            paint(&format!("{label:<14}"), Tone::Muted, color),
            paint(value, Tone::Value, color)
        );
    }
}

pub(crate) fn status(label: &str, message: &str, tone: Tone) {
    eprintln!(
        "   {}  {message}",
        paint(label, tone, color_enabled(io::stderr().is_terminal()))
    );
}

pub(crate) fn success(message: &str) {
    if io::stdout().is_terminal() {
        let color = color_enabled(true);
        println!(
            "\n{}",
            separator(
                "RESULT",
                usize::from(Term::stdout().size().1).min(80),
                color
            )
        );
        println!("   {}  {message}", paint("OK", Tone::Success, color));
    } else {
        println!("{message}");
    }
}

pub(crate) fn spinner(message: &str) -> ProgressBar {
    if !io::stderr().is_terminal() || std::env::var_os("TERM").is_some_and(|value| value == "dumb")
    {
        return ProgressBar::hidden();
    }
    let bar = ProgressBar::new_spinner();
    let template = if color_enabled(true) {
        "   {spinner:.cyan}  {msg}"
    } else {
        "   {spinner}  {msg}"
    };
    bar.set_style(
        ProgressStyle::with_template(template)
            .expect("the static spinner template is valid")
            .tick_strings(&["|", "/", "-", "\\"]),
    );
    bar.set_message(message.to_owned());
    bar.enable_steady_tick(std::time::Duration::from_millis(100));
    bar
}

pub(crate) struct ConfirmTheme {
    pub(crate) color: bool,
}

impl Theme for ConfirmTheme {
    fn format_confirm_prompt(
        &self,
        output: &mut dyn fmt::Write,
        prompt: &str,
        default: Option<bool>,
    ) -> fmt::Result {
        let yes = paint(
            if default == Some(true) { "Y" } else { "y" },
            Tone::Success,
            self.color,
        );
        let no = paint(
            if default == Some(false) { "N" } else { "n" },
            Tone::Error,
            self.color,
        );
        write!(
            output,
            "   {}  {prompt} [{yes}/{no}] ",
            paint("?", Tone::Warning, self.color)
        )
    }

    fn format_confirm_prompt_selection(
        &self,
        output: &mut dyn fmt::Write,
        prompt: &str,
        selection: Option<bool>,
    ) -> fmt::Result {
        write!(
            output,
            "   {prompt} {}",
            paint(
                selection.map_or("", |value| if value { "yes" } else { "no" }),
                if selection == Some(true) {
                    Tone::Success
                } else {
                    Tone::Error
                },
                self.color
            )
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn separators_fit_width_and_plain_output_has_no_escapes() {
        assert_eq!(separator("BUILD", 20, false), "-- BUILD -----------");
        assert_eq!(separator("BUILD", 4, false), "-- BUILD ");
        assert_eq!(
            dialoguer::console::strip_ansi_codes(&separator("BUILD", 20, true)),
            separator("BUILD", 20, false)
        );
        for tone in [
            Tone::Accent,
            Tone::Value,
            Tone::Success,
            Tone::Warning,
            Tone::Error,
            Tone::Muted,
        ] {
            assert_eq!(paint("hello", tone, false), "hello");
            assert!(paint("hello", tone, true).ends_with("\x1b[0m"));
        }
    }

    #[test]
    fn non_terminal_never_enables_color() {
        assert!(!color_enabled(false));
    }

    #[test]
    fn confirmation_keeps_safe_default_and_explicit_selection() {
        let mut rendered = String::new();
        ConfirmTheme { color: false }
            .format_confirm_prompt(&mut rendered, "Activate?", Some(false))
            .unwrap();
        assert!(dialoguer::console::strip_ansi_codes(&rendered).contains("Activate? [y/N]"));
        for (selection, expected) in [(Some(true), "yes"), (Some(false), "no"), (None, "")] {
            rendered.clear();
            ConfirmTheme { color: false }
                .format_confirm_prompt_selection(&mut rendered, "Activate?", selection)
                .unwrap();
            assert_eq!(
                dialoguer::console::strip_ansi_codes(&rendered),
                format!("   Activate? {expected}")
            );
        }
    }

    #[test]
    fn confirmation_colors_yes_green_and_no_red() {
        let theme = ConfirmTheme { color: true };
        let mut rendered = String::new();
        theme
            .format_confirm_prompt(&mut rendered, "Activate?", Some(false))
            .unwrap();
        assert!(rendered.contains(&format!(
            "[{}/{}]",
            paint("y", Tone::Success, true),
            paint("N", Tone::Error, true)
        )));
        for (selection, text, tone) in [(true, "yes", Tone::Success), (false, "no", Tone::Error)] {
            rendered.clear();
            theme
                .format_confirm_prompt_selection(&mut rendered, "Activate?", Some(selection))
                .unwrap();
            assert!(rendered.ends_with(&paint(text, tone, true)));
        }
    }
}
