mod connector;
use std::process::ExitCode;
fn main() -> ExitCode {
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    if let [service, action] = args.as_slice()
        && service == "service"
    {
        return match licoup_mcp::lifecycle::execute(action) {
            Ok(result) => {
                println!("{result}");
                ExitCode::SUCCESS
            }
            Err(_) => {
                eprintln!("lico-subagent-mcp: service operation failed");
                ExitCode::FAILURE
            }
        };
    }
    connector::main()
}
