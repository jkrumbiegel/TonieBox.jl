module TonieBox
    using HTTP
    using JSON3
    using StructTypes

    function __init__()
        authenticate()
    end

    const AUTH_URL = "https://login.tonies.com/auth/realms/tonies/protocol/openid-connect/token"

    const _access_token = Ref{String}()

    access_token() = if isassigned(_access_token)
        _access_token[]
    else
        error("No access token available. Call `authenticate` first.")
    end

    function authenticate(user, password)
        response = HTTP.post(
            AUTH_URL,
            ["Content-Type" => "application/x-www-form-urlencoded"],
             HTTP.URIs.escapeuri(
                Dict(
                    "grant_type" => "password",
                    "client_id" => "my-tonies",
                    "scope" => "openid",
                    "username" => user,
                    "password" => password
                )
            )
        )
        _access_token[] = JSON3.read(response.body)[:access_token]
        @info "Authentication successful"
        return
    end

    function authenticate()
        @info "Authentication needed."
        print("Username: ")
        user = readline()
        print("Password: ")
        password = readline()
        authenticate(user, password)
    end

    function me()
        HTTP.get(
            "https://api.tonie.cloud/v2/me",
            ["Authorization" => "Bearer $(access_token())"],
        ).body |> JSON3.read
    end

    struct Household
        id::String
        name::String
        image::String
        foreignCreativeTonieContent::Bool
        access::String
        canLeave::Bool
        ownerName::String
    end
    StructTypes.StructType(::Type{Household}) = StructTypes.Struct()

    function households()
        JSON3.read(
            HTTP.get(
                "https://api.tonie.cloud/v2/households",
                ["Authorization" => "Bearer $(access_token())"],
            ).body,
            Vector{Household}
        )
    end

    const _current_household = Ref{Household}()
    function current_household()
        if isassigned(_current_household)
            _current_household[]
        else
            hs = households()
            if length(hs) == 1
                current_household!(only(hs))
            else
                error("No current household set. Can't set household automatically because there are $(length(hs)) households.")
            end
        end
    end

    function current_household!(household::Household)
        _current_household[] = household
    end

    struct DeletedChapter
        title::String
        seconds::Float64
    end
    StructTypes.StructType(::Type{DeletedChapter}) = StructTypes.Struct()

    struct TranscodingError
        reason::String
        deletedChapters::Vector{DeletedChapter}
    end
    StructTypes.StructType(::Type{TranscodingError}) = StructTypes.Struct()

    struct Chapter
        id::String
        title::String
        file::String
        seconds::Float64
        transcoding::Bool
    end
    StructTypes.StructType(::Type{Chapter}) = StructTypes.Struct()
    Base.show(io::IO, c::Chapter) = print(io, """Chapter(title: "$(c.title)", seconds: $(c.seconds))""")

    struct CreativeTonie
        id::String
        householdId::String
        name::String
        live::Bool
        private::Bool
        imageUrl::String
        transcodingErrors::Vector{TranscodingError}
        secondsRemaining::Float64
        secondsPresent::Float64
        chaptersRemaining::Int
        chaptersPresent::Int
        transcoding::Bool
        chapters::Vector{Chapter} 
    end
    StructTypes.StructType(::Type{CreativeTonie}) = StructTypes.Struct()
    Base.show(io::IO, ct::CreativeTonie) = print(io, """CreativeTonie(name: "$(ct.name)")""")

    function creativetonies(household = current_household())
        JSON3.read(
            HTTP.get(
                "https://api.tonie.cloud/v2/households/$(household.id)/creativetonies",
                ["Authorization" => "Bearer $(access_token())"],
            ).body,
            Vector{CreativeTonie}
        )
    end

    function create_presigned_file_url()
        JSON3.read(
            HTTP.post(
                "https://api.tonie.cloud/v2/file",
                ["Authorization" => "Bearer $(access_token())"],
            ).body
        )
    end

    struct AddChapter
        title::String
        file::String
        origin::String
    end
    StructTypes.StructType(::Type{AddChapter}) = StructTypes.Struct()

    function add_chapter_to_creative_tonie(tonie::CreativeTonie, file, title; origin = "file-julia")
        @assert isfile(file)

        @info "Creating pre-signed file url"
        presigned_file_info = create_presigned_file_url()
        fileId = presigned_file_info.fileId
        request = presigned_file_info.request

        addchapter = AddChapter(
            title,
            fileId,
            origin,
        )

        amazon_url = request.url
        multiparts = collect(pairs(request.fields))

        @info "Uploading file to Amazon S3."
        open(file) do io
            HTTP.post(
                amazon_url,
                [],
                HTTP.Form(
                    vcat(multiparts, "file" => io)
                )
            )
        end

        @info "Adding uploaded file to chapter list. [id=$fileId]"
        HTTP.post(
            "https://api.tonie.cloud/v2/households/$(tonie.householdId)/creativetonies/$(tonie.id)/chapters",
            ["Content-Type" => "application/json", "Authorization" => "Bearer $(access_token())"],
            JSON3.write(addchapter)
        )
        return
    end

    function remove_chapter(creativetonie::CreativeTonie, chapter::Chapter; household = current_household())
        remaining_chapters = filter(!=(chapter), creativetonie.chapters)
        @assert length(remaining_chapters) == length(creativetonie.chapters) - 1
        @info "Deleting chapter '$(chapter.title)' from creative tonie '$(creativetonie.name)'."
        HTTP.patch(
            "https://api.tonie.cloud/v2/households/$(household.id)/creativetonies/$(creativetonie.id)",
            ["Content-Type" => "application/json", "Authorization" => "Bearer $(access_token())"],
            JSON3.write(Dict(
                "chapters" => remaining_chapters
            ))
        )
        @info "Deletion successful."
        return
    end

    function download_mp3(f, url; from = nothing, to = nothing)
        mktempdir() do path
            filetrunk = joinpath(path, "download")
            filename = filetrunk * ".%(ext)s"
            filename_mp3 = filetrunk * ".mp3"
            run(```yt-dlp -x --audio-format mp3 -o $filename $url```)
            if from !== nothing || to !== nothing
                filename_mp3_temp = filetrunk * "_temp.mp3"
                mv(filename_mp3, filename_mp3_temp)
                run(```ffmpeg -i $filename_mp3_temp $(from === nothing ? `` : `-ss $from`) $(to === nothing ? `` : `-to $to`) -c copy $filename_mp3```)
                rm(filename_mp3_temp)
            end
            @assert isfile(filename_mp3)
            f(filename_mp3)
        end
    end

    function download_mp3_and_add_chapter(creativetonie, url, title; from = nothing, to = nothing)
        download_mp3(url; from = from, to = to) do filepath
            add_chapter_to_creative_tonie(creativetonie, filepath, title)
        end
    end

    find_chapters(ct::CreativeTonie, r::Regex) = filter(c -> match(r, c.title), ct.chapters)
    find_chapters(ct::CreativeTonie, s::AbstractString) = filter(c -> occursin(s, c.title), ct.chapters)

    function remove_chapters(ct::CreativeTonie, matcher)
        chapters = find_chapters(ct, matcher)
        io = IOBuffer()
        println(io, "This would remove the following chapters:")
        for c in chapters
            println(io, "  - $(c.title)")
        end
        @info String(take!(io))
        println("Type y to remove:")
        s = readline()
        if s == "y"
            for c in chapters
                remove_chapter(ct, c)
            end
        else
            @info "Not removed."
        end
    end
end
