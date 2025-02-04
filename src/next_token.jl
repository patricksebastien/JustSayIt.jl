@doc """
    is_next(token)

!!! note "Advanced"
    is_next(token; <keyword arguments>)

Check if `token` is the next token in the speech; if yes, return `true`, else, return `false`. If `token` is an array of strings, check if any of them is the next token in the speech. A call to `is_next` does by default not consume the next token (nor fix the recognizer to be used for its recognition).

# Arguments
- `token::String | AbstractArray{String}`: the token(s) to compare the next token in the speech against.
!!! note "Advanced keyword arguments"
	- `modelname::String=DEFAULT_MODEL_NAME`: the name of the model to be used for the recognition in the token comparison (the name must be one of the keys of the modeldirs dictionary passed to `init_jsi`).
	- `consume_if_match::Bool=false`: whether the next token is to be consumed in case of a match.
	- `timeout::Float64=Inf`: timeout after which to abort waiting for a next token to be spoken.
	- `use_max_accuracy::Bool=false`: whether to use maxium accuracy for the recognition of the next token (rather than maximum speed). It is only recommended to set `use_max_accuracy=true` if the next cluster of tokens is in any case to be recognised with maxium accuracy (typically used with a free speech recognizer, i.e. with a large vocabulary),

See also: [`init_jsi`](@ref)
"""
is_next

let
    global next_token, is_next, _is_next, are_next, recognizer, force_reset_previous, all_consumed, was_partial_recognition, reset_all, do_delayed_resets # NOTE: recogniser needs to be declared global here, even if elsewhere the method created here might not be used, as else we do not have access to the other reconizer methods here.
    recognizers_to_reset = Vector{PyObject}()
    active_recognizer::Union{Nothing, PyObject} = nothing
    was_partial_result = false
    token_buffer = Vector{String}()
    i = 0
	all_consumed()::Bool            = (i >= length(token_buffer))
	was_partial_recognition()::Bool = was_partial_result


    function next_token(recognizer::PyObject, noise_tokens::AbstractArray{String}; consume::Bool=true, timeout::Float64=Inf, use_partial_recognitions::Bool=false, restart_recognition::Bool=false, ignore_unknown::Bool=true)
		ignore_tokens = ignore_unknown ? [noise_tokens..., UNKNOWN_TOKEN] : noise_tokens
		if (recognizer != active_recognizer && !isnothing(active_recognizer) && !isempty(token_buffer) && i==0) # If the recognizer was changed despite that tokens were recognized, but none was consumed, then we will always want to restart recognition.
			 restart_recognition = true
		end
		if (!was_partial_result) do_delayed_resets(;hard=false) end                                 # When a result was found, then soft resets that were previously delayed to keep latency minimal can now be performed.
		if (recognizer != active_recognizer && was_partial_result && !isnothing(active_recognizer)) # Reset the active recognizer if a new recognizer will become active. #NOTE: Reset after a result is not needed and a hard reset leads to the following Vosk error in that case: ASSERTION_FAILED (VoskAPI:ComputeFinalCosts():lattice-faster-decoder.cc:540) Assertion failed: (!decoding_finalized_)
			if restart_recognition push!(recognizers_to_reset, active_recognizer)
			else                   reset(active_recognizer; hard=true)
			end
		end
		t  = 0.0
        t0 = tic()
        token = ""
        while token == "" && (t < timeout)
			if all_consumed() || (recognizer != active_recognizer) || (!use_partial_recognitions && was_partial_result && !all_consumed())  # NOTE: if there are tokens left in the buffer that have been recognised with a different recogniser we cannot use them for safety reasons.
				reset_audio_buffer = (i >= length(token_buffer)) && !was_partial_result && !restart_recognition                             # Reset the audio buffer if all tokens in the token buffer were consumed, the last recognition was not partial and we do not want to restart (meaning here redo) the recognition. This means that the last recognition is now final and cannot be revised anymore.
				@debug "==========================================\nRecognition parameters:" use_partial_recognitions timeout restart=restart_recognition reset_audio_buffer
	            if use_partial_recognitions
	                text, is_partial_result, has_timed_out = next_partial_recognition(recognizer; timeout=timeout, restart=restart_recognition, reset_audio_buffer=reset_audio_buffer)
	            else
	                text = next_recognition(recognizer; timeout=timeout, restart=restart_recognition, reset_audio_buffer=reset_audio_buffer)
	                is_partial_result = false
	            end
				if restart_recognition  || ((recognizer == active_recognizer) && was_partial_result)
					tokens = filter(x -> x ∉ ignore_tokens, split(text))
					if !startswith(join(tokens, " "), join(token_buffer[1:i], " "))  # NOTE: a maybe cheaper, but less safe alternative would probably be `!issubset(token_buffer[1:i], tokens)`. It is less safe as issubset will not guarantee the order (for the same reason, it might be more expensive in the end: more cases to test...).
						@debug "Insecurity - after restart?:" restart=restart_recognition
						msg = "Insecurity in recognition: the tokens recognised in the previous (partial) recognition that have been consumed are not a subset of the tokens now recognised (token_buffer: $(token_buffer[1:i]); tokens: $tokens)"
						if (is_partial_result) recognizer.Reset() end                #NOTE: Reset after a result is not needed and leads to the following Vosk error: ASSERTION_FAILED (VoskAPI:ComputeFinalCosts():lattice-faster-decoder.cc:540) Assertion failed: (!decoding_finalized_)
				        reset_token_buffer()
						reset_audio()
						active_recognizer = nothing
						was_partial_result = false
						@InsecureRecognitionException(msg)
					end
					token_buffer = tokens
				else
		            token_buffer = filter(x -> x ∉ ignore_tokens, split(text))
		            i = 0
				end
				was_partial_result = is_partial_result
				active_recognizer  = recognizer
	        end
	        if i < length(token_buffer)
				i += 1
				@debug "" token_buffer token=token_buffer[i]
				token = token_buffer[i]
				if (!consume) i-=1 end
			end
			restart_recognition = false  # A restart needs to happen in the first iteration if set, then not anymore.
			t = toc(t0)
        end
        return token
    end

	function next_token(recognizer_info::Tuple{Symbol,Symbol,<:AbstractArray{String},String}, noise_tokens::AbstractArray{String}; consume::Bool=true, timeout::Float64=Inf, use_partial_recognitions::Bool=false, force_dynamic_recognizer::Bool=false, ignore_unknown::Bool=true)
		if (i >= length(token_buffer)) && !was_partial_result && !force_dynamic_recognizer  # If all tokens in the buffer were consumed and the last recognition was not partial, then we can swap the recogniser without having to consider the last recognitions (i.e., get the recognizer created in init_jsi)...
			f_name, voicearg = recognizer_info[1:2]
			next_token(recognizer(f_name, voicearg), noise_tokens; consume=consume, timeout=timeout, use_partial_recognitions=use_partial_recognitions, ignore_unknown=ignore_unknown)
		else                                                                                # ...else, we are swapping the recognizer while the recognition was only partial and/or not all tokens consumed. Thus, the new recognizer needs to include the audio of the last partial recognition and must be able to recognize the already consumed tokens, i.e., be dynamically created.
			valid_input, modelname = recognizer_info[3:4]
			next_token(recognizer(valid_input, noise_tokens; modelname=modelname), noise_tokens; consume=consume, timeout=timeout, use_partial_recognitions=use_partial_recognitions, restart_recognition=true, ignore_unknown=ignore_unknown)
        end
	end

	function next_token(valid_input::AbstractArray{String}; modelname::String=DEFAULT_MODEL_NAME, noise_tokens::AbstractArray{String}=noises(modelname), consume::Bool=true, timeout::Float64=Inf, use_partial_recognitions::Bool=false, ignore_unknown::Bool=true)
		recognizer_info = (Symbol(), Symbol(), valid_input, modelname)
		next_token(recognizer_info, noise_tokens; consume=consume, timeout=timeout, use_partial_recognitions=use_partial_recognitions, force_dynamic_recognizer=true, ignore_unknown=ignore_unknown)
	end

	#NOTE: this function will only consume the next token if `consume_if_match` is set true and the token matches.
	function _is_next(token::Union{String,AbstractArray{String}}, recognizer_or_info::Union{PyObject, Tuple{Symbol,Symbol,<:AbstractArray{String},String}}, noise_tokens::AbstractArray{String}; consume_if_match::Bool=false, timeout::Float64=Inf, use_partial_recognitions::Bool=false, force_dynamic_recognizer::Bool=false, ignore_unknown::Bool=false)
		test_token = next_token(recognizer_or_info, noise_tokens; consume=true, timeout=timeout, use_partial_recognitions=use_partial_recognitions, force_dynamic_recognizer=force_dynamic_recognizer, ignore_unknown=ignore_unknown)
		is_match = isa(token, String) ? (test_token == token) : (test_token in token)
		if !(consume_if_match && is_match) i -= 1 end # Correct the token_buffer index in order to return the same token again in the next next_token call.
		return is_match
	end

	function is_next(token::Union{String,AbstractArray{String}}, valid_input::AbstractArray{String}; modelname::String=DEFAULT_MODEL_NAME, noise_tokens::AbstractArray{String}=noises(modelname), consume_if_match::Bool=false, timeout::Float64=Inf, use_max_accuracy::Bool=true, ignore_unknown::Bool=false)
		recognizer_info = (Symbol(), Symbol(), valid_input, modelname)
		_is_next(token, recognizer_info, noise_tokens; consume_if_match=consume_if_match, timeout=timeout, use_partial_recognitions=!use_max_accuracy, force_dynamic_recognizer=true, ignore_unknown=ignore_unknown)
	end

	function is_next(token::Union{String,AbstractArray{String}}; modelname::String=DEFAULT_MODEL_NAME, noise_tokens::AbstractArray{String}=noises(modelname), consume_if_match::Bool=false, timeout::Float64=Inf, use_max_accuracy::Bool=true, ignore_unknown::Bool=false)
		valid_input = isa(token, String) ? [token] : token
		is_next(token, valid_input; modelname=modelname, noise_tokens=noise_tokens, consume_if_match=consume_if_match, timeout=timeout, use_max_accuracy=use_max_accuracy, ignore_unknown=ignore_unknown)
	end

	#NOTE: this function will only consume the next tokens if `consume_if_match` is set true and all the tokens match.
	function _are_next(token::Union{String,AbstractArray{String}}, recognizer_or_info::Union{PyObject, Tuple{Symbol,Symbol,<:AbstractArray{String},String}}, noise_tokens::AbstractArray{String}; consume_if_match::Bool=false, timeout::Float64=Inf, use_partial_recognitions::Bool=false, force_dynamic_recognizer::Bool=false, ignore_unknown::Bool=false)
		match = String[]
		test_token = next_token(recognizer_or_info, noise_tokens; consume=true, timeout=timeout, use_partial_recognitions=use_partial_recognitions, force_dynamic_recognizer=force_dynamic_recognizer, ignore_unknown=ignore_unknown)
		consumed = 1
		is_match = isa(token, String) ? (test_token == token) : (test_token in token)
		if is_match
			push!(match, test_token)
			while is_match && !all_consumed()
				test_token = next_token(recognizer_or_info, noise_tokens; consume=true, timeout=timeout, use_partial_recognitions=use_partial_recognitions, force_dynamic_recognizer=force_dynamic_recognizer, ignore_unknown=ignore_unknown)
				consumed += 1
				is_match = isa(token, String) ? (test_token == token) : (test_token in token)
				if is_match
					push!(match, test_token)
			    else
					i -= 1
					consumed -= 1 # Correct the token_buffer index in order to return the same token again in the next next_token call.
				end
			end
			if (!is_match) match = String[] end
		end
		if !(consume_if_match && is_match) i -= consumed end # Correct the token_buffer index in order to return the same tokens again in the next next_token call.
		return is_match, match
	end

	function are_next(token::Union{String,AbstractArray{String}}, valid_input::AbstractArray{String}; modelname::String=DEFAULT_MODEL_NAME, noise_tokens::AbstractArray{String}=noises(modelname), consume_if_match::Bool=false, timeout::Float64=Inf, use_max_accuracy::Bool=true, ignore_unknown::Bool=false)
		recognizer_info = (Symbol(), Symbol(), valid_input, modelname)
		_are_next(token, recognizer_info, noise_tokens; consume_if_match=consume_if_match, timeout=timeout, use_partial_recognitions=!use_max_accuracy, force_dynamic_recognizer=true, ignore_unknown=ignore_unknown)
	end

	function are_next(token::Union{String,AbstractArray{String}}; modelname::String=DEFAULT_MODEL_NAME, noise_tokens::AbstractArray{String}=noises(modelname), consume_if_match::Bool=false, timeout::Float64=Inf, use_max_accuracy::Bool=true, ignore_unknown::Bool=false)
		valid_input = isa(token, String) ? [token] : token
		are_next(token, valid_input; modelname=modelname, noise_tokens=noise_tokens, consume_if_match=consume_if_match, timeout=timeout, use_max_accuracy=use_max_accuracy, ignore_unknown=ignore_unknown)
	end

	# Create dynamically a recognizer based on the valid input, model and the consumed tokens recognised in the current audio_buffer.
	function recognizer(valid_input::AbstractArray{String}, noise_tokens::AbstractArray{String}; modelname::String=DEFAULT_MODEL_NAME)
		ignore_tokens = [noise_tokens..., UNKNOWN_TOKEN]
		consumed_tokens = join(token_buffer[1:i], " ")
		if isempty(consumed_tokens)
			valid_strings = [valid_input..., ignore_tokens...]
		else
			valid_strings = map([valid_input..., ignore_tokens...]) do x
				join((consumed_tokens, x), " ")
			end
		end
		@debug "Dynamic recognizer created for the following grammar: $valid_strings"
		grammar = json(valid_strings)
		return Vosk.KaldiRecognizer(model(modelname), SAMPLERATE, grammar)
	end

    function reset_token_buffer()
        token_buffer = Vector{String}()
        i = 0
    end

	# #NOTE: this function which is to be called after consuming a partial result, continues with the recognition until a result is obtained.
	function reset(recognizer::PyObject; timeout::Float64=60.0, hard::Bool=true)
		@debug "Resetting recognizer ($(hard ? "hard" : "soft") reset)."
		if (hard) recognizer.Reset()                                                                    # NOTE: a hard reset may lead to a audio cut in the middle of speech and as a result recognise some tokens twice etc.
		else      next_recognition(recognizer; timeout=timeout, restart=true, reset_audio_buffer=false) # NOTE: as soft reset will lead to lost tokens, if it is not followed by a restart
		end
	    return
	end

	function do_delayed_resets(; timeout::Float64=60.0, hard::Bool=true)
		for r in recognizers_to_reset
			reset(r; timeout=timeout, hard=hard)
		end
		recognizers_to_reset = Vector{PyObject}()
	end

	function force_reset_previous(recognizer::Union{PyObject, Nothing}; timeout::Float64=60.0, hard::Bool=false)
		if (recognizer != active_recognizer && was_partial_result && !isnothing(active_recognizer)) # Reset the active recognizer if a new recognizer will become active.
			reset(active_recognizer; timeout=timeout, hard=hard)
			do_delayed_resets(;timeout=timeout, hard=hard)
			reset_token_buffer()
			reset_audio()
			active_recognizer = nothing
			was_partial_result = false
		end
	end

	function reset_all(; timeout::Float64=60.0, hard::Bool=false, exclude_active::Bool=false)
		if (!exclude_active) reset(active_recognizer; timeout=timeout, hard=hard) end
		do_delayed_resets(;timeout=timeout, hard=hard)
		reset_token_buffer()
		reset_audio()
		active_recognizer = nothing
		was_partial_result = false
	end

end


let
    global next_recognition, next_partial_recognition, t0_latency, reset_audio
	audio_buffer          = zeros(UInt8, AUDIO_ALLOC_GRANULARITY)
	audio_chunk           = zeros(UInt8, AUDIO_READ_MAX)
	i                     = 0
    partial_result_old    = ""
	has_timed_out         = false
    t_read_sum            = 0.0
    t_read_max            = 0.0
    t_recognize_sum       = 0.0
    t_recognize_max       = 0.0
    t_sum                 = 0.0
    t_max                 = 0.0
    bytes_read_sum        = 0
    it_result             = 0 # iteration (while not converged to result)
    _t0_latency::Float64  = 0.0
    t0_latency()::Float64 = _t0_latency
	reset_audio()         = (i = 0; return)

    function next_partial_recognition(recognizer::PyObject; timeout::Float64=60.0, restart::Bool=false, reset_audio_buffer::Bool=false)
        is_partial_result = true
        partial_result    = ""
        text              = ""
		if (reset_audio_buffer) i = 0 end
		if (has_timed_out) restart = true end
		if (restart) partial_result_old = "" end
		i0 = i
		it = 0
        t  = 0.0
        t0 = tic()
        while (text == "") && (t < timeout)
            t1 = tic()
			if i + AUDIO_READ_MAX > length(audio_buffer)
				resize!(audio_buffer, length(audio_buffer) + AUDIO_ALLOC_GRANULARITY)
			end
			tic();  bytes_read = readbytes!(recorder(), audio_chunk);  t_read_sum+=toc(); t_read_max=max(t_read_max,toc()) #; println("t_read: $(toc())")
            if bytes_read > 0
				it += 1
                _t0_latency = tic() # NOTE: when the while loop is left, this value will contain the time right before the call to the recognizer, which lead to a successful partial or full recognition. It allows to compute the latency from when the reading of a command was completed (which can be considered equivalent to the time it the speaker completed it, if bytes_read per iteration is small) to the invocation of a command (toc() needs to be called right before its invocation).
				audio_buffer[i+1:i+bytes_read] .= audio_chunk[1:bytes_read]
				i += bytes_read
				if restart && (it == 1)
					audio = pybytes(audio_buffer[1:i])                                                                #NOTE: an allocation is unavoidable in the case of a restrt as pybytes cannot handle views. However, it is required only in the first iteration.
				else
					audio = (bytes_read < AUDIO_READ_MAX) ? pybytes(audio_chunk[1:bytes_read]) : pybytes(audio_chunk) #NOTE: an allocation should only be done if bytes_read < AUDIO_READ_MAX (required in order to avoid having random data at the end of the audio_chunk).
				end
                tic();  exitcode = recognizer.AcceptWaveform(audio);  t_recognize_sum+=toc(); t_recognize_max=max(t_recognize_max,toc())  #; println("t_recognize: $(toc())")
                is_partial_result = (exitcode == 0)
                if is_partial_result
                    partial_result = recognizer.PartialResult()
                    if (partial_result != partial_result_old) text = (JSON.parse(partial_result))["partial"] end
                else
                    result = recognizer.Result()
                    text = (JSON.parse(result))["text"]
                end
                bytes_read_sum += bytes_read
				if (i0 == 0 || has_timed_out) && (i >= 2*AUDIO_HISTORY_MIN) && (text == "")   # If we have started without audio history to consider, then we cut off silence at its beginning every now and then (to avoid that if we restart, we have a lot of silence to process). We know that what we cut off is silence, because else we would have obtained a partial recognition (AUDIO_HISTORY_MIN must be bigger than the amount of audio that maximally leads to a partial recognition if it is not silence).
					@debug "Cutting off silence in audio beginning:" i0 has_timed_out i AUDIO_HISTORY_MIN text
					audio_buffer[1:AUDIO_HISTORY_MIN] .= @view audio_buffer[i-AUDIO_HISTORY_MIN+1:i]
					i = AUDIO_HISTORY_MIN
				end
            end
            t = toc(t0); #; println("t: $t")
            t_sum+=toc(t1); t_max=max(t_max,toc(t1))
        end
		it_result += it
        @debug join([".........................................."
			"Iterations: $it_result (average Bytes/it_result: $(bytes_read_sum/it_result))"
        	"READ:      throughput [KB/s]: $(round(bytes_read_sum/t_read_sum/1e3, sigdigits=2)) (average [s]: $(round(t_read_sum/it_result, sigdigits=2)), max [s]: $(round(t_read_max, sigdigits=2)), sum [s]: $(round(t_read_sum, sigdigits=2)))"
        	"RECOGNISE: throughput [KB/s]: $(round(bytes_read_sum/t_recognize_sum/1e3, sigdigits=2)) (average [s]: $(round(t_recognize_sum/it_result, sigdigits=2)) max [s]: $(round(t_recognize_max, sigdigits=2)), sum [s]: $(round(t_recognize_sum, sigdigits=2)))"
        	"TOTAL:     effective throughput [KB/s]: $(round(bytes_read_sum/t_sum/1e3, sigdigits=2)) (average [s]: $(round(t_sum/it_result, sigdigits=2)) max [s]: $(round(t_max, sigdigits=2)), sum [s]: $(round(t_sum, sigdigits=2)))"
			is_partial_result ? "Partial result: $text" : "Result: $text"
		], "\n")
        if is_partial_result
            partial_result_old = partial_result
        else
            partial_result_old = ""
            t_read_sum         = 0.0
            t_recognize_sum    = 0.0
            t_sum              = 0.0
            bytes_read_sum     = 0
            it_result          = 0
        end
        has_timed_out = (t >= timeout)
		if (has_timed_out) _t0_latency=0.0 end
        return text, is_partial_result, has_timed_out
    end

    function next_recognition(recognizer::PyObject; timeout::Float64=120.0, restart::Bool=false, reset_audio_buffer::Bool=false)
        is_partial_result = true
        text = ""
        t  = 0.0
        t0 = tic()
		text, is_partial_result = next_partial_recognition(recognizer; timeout=timeout, restart=restart, reset_audio_buffer=reset_audio_buffer)
		t = toc(t0)
        while is_partial_result && (t < timeout)
            text, is_partial_result = next_partial_recognition(recognizer; timeout=timeout, restart=false, reset_audio_buffer=false)
            t = toc(t0)
        end
        return text
    end

end
