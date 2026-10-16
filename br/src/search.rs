use std::io::{self, IsTerminal, Write};
use std::cmp::Ordering;

use anyhow::{Context, Result};
use rusqlite::{Connection, OpenFlags};

use crate::{state, ui};

pub(crate) fn search(query: &str, versions: bool, exact: bool) -> Result<()> {
    let path = state::path_env("BR_MULTIVERSE_DB", "/etc/br/multiverse.db");
    let connection = Connection::open_with_flags(&path, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .with_context(|| format!("opening multiverse index {}", path.display()))?;
    // Use instr rather than LIKE so wildcard characters in the query remain literal.
    let sql = match (versions, exact) {
        (true, true) => {
            "SELECT a.name, p.version, 1
             FROM attrs a JOIN pairs p ON p.attr_id = a.id
             WHERE lower(a.name) = lower(?1)
             ORDER BY a.name, p.version"
        }
        (true, false) => {
            "SELECT a.name, p.version, 1
             FROM attrs a JOIN pairs p ON p.attr_id = a.id
             WHERE instr(lower(a.name), lower(?1)) > 0
             ORDER BY CASE WHEN lower(a.name) = lower(?1) THEN 0
                           WHEN instr(lower(a.name), lower(?1)) = 1 THEN 1 ELSE 2 END,
                       a.name, p.version"
        }
        (false, true) => {
            "SELECT a.name, max(CASE WHEN p.tip = 1 THEN p.version END), count(*)
             FROM attrs a JOIN pairs p ON p.attr_id = a.id
             WHERE lower(a.name) = lower(?1)
             GROUP BY a.id
             ORDER BY a.name"
        }
        (false, false) => {
            "SELECT a.name, max(CASE WHEN p.tip = 1 THEN p.version END), count(*)
             FROM attrs a JOIN pairs p ON p.attr_id = a.id
             WHERE instr(lower(a.name), lower(?1)) > 0
             GROUP BY a.id
             ORDER BY CASE WHEN lower(a.name) = lower(?1) THEN 0
                           WHEN instr(lower(a.name), lower(?1)) = 1 THEN 1 ELSE 2 END,
                      a.name"
        }
    };
    let mut statement = connection
        .prepare(sql)
        .context("preparing multiverse search")?;
    let rows = statement
        .query_map([query], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, Option<String>>(1)?,
                row.get::<_, i64>(2)?,
            ))
        })
        .context("querying multiverse index")?;
    let mut output = io::stdout().lock();
    let terminal = output.is_terminal();
    let color = ui::color_enabled(terminal);
    if terminal {
        writeln!(
            output,
            "\n{}",
            ui::separator(
                "SEARCH",
                usize::from(dialoguer::console::Term::stdout().size().1).min(80),
                color
            )
        )
        .context("writing search results")?;
        if !versions {
            writeln!(output, "   PACKAGE\tTIP VERSION\tVERSIONS")
                .context("writing search results")?;
        }
    }
    let mut results = rows
        .map(|row| row.context("reading multiverse search result"))
        .collect::<Result<Vec<_>>>()?;
    if versions {
        results.sort_by(|left, right| {
            let rank = |name: &str| {
                let name = name.to_lowercase();
                let query = query.to_lowercase();
                if name == query {
                    0
                } else if name.starts_with(&query) {
                    1
                } else {
                    2
                }
            };
            let name_order = rank(&left.0)
                .cmp(&rank(&right.0))
                .then_with(|| left.0.cmp(&right.0));
            if name_order != Ordering::Equal {
                return name_order;
            }
            compare_versions(
                left.1.as_deref().unwrap_or_default(),
                right.1.as_deref().unwrap_or_default(),
            )
        });
    }
    let mut count = 0;
    for (name, version, version_count) in results {
        let name = ui::paint(&name, ui::Tone::Accent, color);
        let version = ui::paint(version.as_deref().unwrap_or("-"), ui::Tone::Value, color);
        let indent = if terminal { "   " } else { "" };
        if versions {
            writeln!(output, "{indent}{name}@{version}")
        } else {
            writeln!(output, "{indent}{name}\t{version}\t{version_count}")
        }
        .context("writing search results")?;
        count += 1;
    }
    if terminal {
        writeln!(output, "\n   {count} matches").context("writing search results")?;
        if versions {
            writeln!(
                output,
                "   Tip: add --nonexact to include names containing the search query."
            )
            .context("writing search results")?;
        } else {
            writeln!(output, "   Tip: indexed tip version; - means historical versions only.\n   Use --versions to list indexed name@version identities.")
                .context("writing search results")?;
        }
    }
    Ok(())
}

fn compare_versions(left: &str, right: &str) -> Ordering {
    let mut left_parts = left.split('.');
    let mut right_parts = right.split('.');
    loop {
        match (left_parts.next(), right_parts.next()) {
            (Some(left), Some(right)) => {
                let order = match (left.parse::<u64>(), right.parse::<u64>()) {
                    (Ok(left), Ok(right)) => left.cmp(&right),
                    _ => left.cmp(right),
                };
                if order != Ordering::Equal {
                    return order;
                }
            }
            (None, Some(_)) => return Ordering::Less,
            (Some(_), None) => return Ordering::Greater,
            (None, None) => return left.cmp(right),
        }
    }
}
