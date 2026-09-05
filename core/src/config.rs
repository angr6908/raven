use std::env;
use std::path::{Path, PathBuf};

pub const VERSION: &str = env!("CARGO_PKG_VERSION");
pub const DEFAULT_PORT: u16 = 3458;

pub struct Config {
    pub address: String,
    pub api_base: String,
    pub work_dir: PathBuf,
    pub data_dir: PathBuf,
    pub static_dir: PathBuf,
    pub cli_version: String,
}

struct Flags {
    host: String,
    port: u16,
    api_base: String,
    work_dir: String,
    data_dir: String,
    static_dir: String,
    cli_version: String,
    version: bool,
}

impl Config {
    pub fn from_args(args: Vec<String>) -> Result<Option<Self>, String> {
        let flags = parse(args)?;
        if flags.version {
            return Ok(None);
        }

        let work_dir = match flags.work_dir.is_empty() {
            true => env::current_dir().unwrap_or_else(|_| home_dir()),
            false => PathBuf::from(flags.work_dir),
        };
        let data_dir = match flags.data_dir.is_empty() {
            true => work_dir.clone(),
            false => PathBuf::from(flags.data_dir),
        };
        let static_dir = match flags.static_dir.is_empty() {
            true => work_dir.join("app").join("dist"),
            false => PathBuf::from(flags.static_dir),
        };

        Ok(Some(Self {
            address: format!("{}:{}", flags.host, flags.port),
            api_base: flags.api_base.trim_end_matches('/').to_string(),
            work_dir,
            data_dir,
            static_dir,
            cli_version: flags.cli_version,
        }))
    }

    pub fn work_dir(&self) -> &Path {
        &self.work_dir
    }
}

fn parse(args: Vec<String>) -> Result<Flags, String> {
    let mut flags = Flags {
        host: "127.0.0.1".to_string(),
        port: DEFAULT_PORT,
        api_base: String::new(),
        work_dir: String::new(),
        data_dir: String::new(),
        static_dir: String::new(),
        cli_version: String::new(),
        version: false,
    };

    let mut index = 1;
    while index < args.len() {
        let arg = args[index].clone();
        if arg == "--version" || arg == "-version" {
            flags.version = true;
            index += 1;
            continue;
        }
        let Some((name, inline)) = split_flag(&arg) else {
            return Err(format!("unknown flag: {arg}"));
        };
        let value = match inline {
            Some(value) => value,
            None => {
                index += 1;
                args.get(index)
                    .cloned()
                    .ok_or_else(|| format!("missing value for {arg}"))?
            }
        };
        apply(&mut flags, name, &value)?;
        index += 1;
    }
    Ok(flags)
}

fn split_flag(arg: &str) -> Option<(&str, Option<String>)> {
    let body = arg.strip_prefix("--").or_else(|| arg.strip_prefix('-'))?;
    match body.split_once('=') {
        Some((name, value)) => Some((name, Some(value.to_string()))),
        None => Some((body, None)),
    }
}

fn apply(flags: &mut Flags, name: &str, value: &str) -> Result<(), String> {
    match name {
        "host" => flags.host = value.to_string(),
        "port" => {
            flags.port = value
                .parse()
                .map_err(|_| format!("invalid port: {value}"))?
        }
        "api-base" => flags.api_base = value.to_string(),
        "working-dir" => flags.work_dir = value.to_string(),
        "data-dir" => flags.data_dir = value.to_string(),
        "static-dir" => flags.static_dir = value.to_string(),
        "cc-version" => flags.cli_version = value.to_string(),
        other => return Err(format!("unknown flag: --{other}")),
    }
    Ok(())
}


fn home_dir() -> PathBuf {
    env::var_os("HOME")
        .or_else(|| env::var_os("USERPROFILE"))
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config(args: &[&str]) -> Config {
        let mut argv = vec!["raven".to_string()];
        argv.extend(args.iter().map(|arg| arg.to_string()));
        Config::from_args(argv).unwrap().unwrap()
    }

    #[test]
    fn flags_accept_both_inline_and_separate_values() {
        assert_eq!(config(&["-port", "9000"]).address, "127.0.0.1:9000");
        assert_eq!(config(&["--port=9001"]).address, "127.0.0.1:9001");
        assert_eq!(config(&["--host=0.0.0.0"]).address, "0.0.0.0:3458");
    }

    #[test]
    fn static_dir_defaults_under_the_work_dir() {
        assert_eq!(
            config(&["-working-dir", "/w"]).static_dir,
            PathBuf::from("/w/app/dist")
        );
        assert_eq!(
            config(&["-working-dir", "/w", "-static-dir", "/x/dist"]).static_dir,
            PathBuf::from("/x/dist")
        );
    }

    #[test]
    fn data_dir_defaults_to_the_work_dir() {
        assert_eq!(config(&["-working-dir", "/w"]).data_dir, PathBuf::from("/w"));
    }

    #[test]
    fn version_starts_nothing() {
        let argv = vec!["raven".to_string(), "--version".to_string()];
        assert!(Config::from_args(argv).unwrap().is_none());
    }

    #[test]
    fn bad_flags_are_rejected() {
        for args in [vec!["raven", "--nope=1"], vec!["raven", "-port", "x"], vec!["raven", "-port"]] {
            let argv = args.into_iter().map(str::to_string).collect();
            assert!(Config::from_args(argv).is_err());
        }
    }
}
