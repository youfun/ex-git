exclude =
  if System.get_env("EX_GIT_GITHUB_URL") in [nil, ""] or
       System.get_env("EX_GIT_GITHUB_TOKEN") in [nil, ""] do
    [:github]
  else
    []
  end

ExUnit.start(exclude: exclude)
