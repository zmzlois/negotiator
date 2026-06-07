## Unsiloed knowledge loader dry run
**What didn't work:** the first converter pass used an unescaped markdown heading regex, then treated missing boolean CLI flags as booleans, then piped strings into `Regex.replace/4` even though Elixir expects the regex as the first argument.
**What worked:** escape the heading marker regex, read boolean flags with `Keyword.get/3`, and use `String.replace/3` for piped regex cleanup.
**Note for next time:** for text cleanup pipelines in Elixir, prefer `String.replace(text, regex, replacement)` or piped `String.replace(regex, replacement)` rather than `Regex.replace/4`.

## Moss document metadata load
**What didn't work:** pushing `%Moss.DocumentInfo{}` with integer, list, and nil metadata values raised `Could not decode field :metadata on %NifDocumentInfo{}` from the Moss NIF.
**What worked:** normalize metadata to a string-only map before calling `Moss.Client.create_index/4` or `Moss.Client.add_docs/4`.
**Note for next time:** keep Moss metadata simple at the adapter boundary; store page numbers, counts, and list fields as strings unless the SDK documents richer metadata support.
