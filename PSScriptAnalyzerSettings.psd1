@{
    # These tools are interactive CLIs that print colored console UX to a human
    # running a migration — Write-Host is the correct choice there, not a bug.
    # Plural cmdlet names (Get-AdoRepos, etc.) reflect that they return
    # collections, an accepted deviation from the singular-noun convention.
    ExcludeRules = @(
        'PSAvoidUsingWriteHost',
        'PSUseSingularNouns'
    )
}
