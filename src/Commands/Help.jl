"""
Module Help

Provides functions for displaying help about the commands during speech recognition.

# Functions
- [`help`](@ref)

To see a description of a function type `?<functionname>`.
"""
module Help

import ..JustSayIt: @voiceargs, TYPE_MODEL_NAME, command, command_names, next_token

const COMMANDS_KEYWORD = "commands"

"Show help for your commands or a spoken command or module."
function help()
    valid_input = [COMMANDS_KEYWORD, command_names()...]
    keyword = next_token(valid_input)
    if keyword == COMMANDS_KEYWORD
        cmd_length_max = maximum(length.(command_names()))
        @info join(["", "Your commands:",
                    map(sort([command_names()...])) do x
                       join((x, command(x)), " "^(cmd_length_max+1-length(x)) * "=> ")
                    end...
                    ], "\n")
    elseif keyword in command_names()
        @info "Command $keyword" ""=Base.Docs.doc(command(keyword))
    else
        @info "Keyword not recognized."
    end
    return
end

end # module Help
