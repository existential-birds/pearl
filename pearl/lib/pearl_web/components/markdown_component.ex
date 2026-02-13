defmodule PearlWeb.MarkdownComponent do
  @moduledoc """
  Component for rendering Markdown content with Mermaid diagram support.
  """

  use Phoenix.Component

  @mermaid_regex ~r/```mermaid\n(?<content>[\s\S]*?)```/
  @mermaid_placeholder "MERMAID_BLOCK_PLACEHOLDER"

  @spec render_markdown(String.t()) :: String.t()
  def render_markdown(markdown) when is_binary(markdown) do
    case Earmark.as_html(markdown, code_class_prefix: "language-") do
      {:ok, html, _warnings} -> HtmlSanitizeEx.markdown_html(html)
      {:error, html, _errors} -> HtmlSanitizeEx.markdown_html(html)
    end
  end

  def render_markdown(_), do: ""

  @spec extract_mermaid(String.t()) :: {String.t(), [String.t()]}
  def extract_mermaid(markdown) do
    mermaid_blocks =
      Regex.scan(@mermaid_regex, markdown, capture: :all_names)
      |> Enum.map(fn [content] -> content end)

    html =
      markdown
      |> replace_mermaid_blocks()
      |> render_markdown()
      |> String.replace(@mermaid_placeholder, ~s(<div class="mermaid-placeholder"></div>))

    {html, mermaid_blocks}
  end

  defp replace_mermaid_blocks(markdown) do
    Regex.replace(@mermaid_regex, markdown, fn _, _content ->
      @mermaid_placeholder
    end)
  end

  attr :content, :string, required: true
  attr :class, :string, default: ""
  attr :id, :string, default: "markdown-content"

  def markdown(assigns) do
    {html, mermaid_blocks} = extract_mermaid(assigns.content || "")
    assigns = assign(assigns, html: html, mermaid_blocks: mermaid_blocks)

    ~H"""
    <div id={@id} phx-hook="Highlight" class={"prose prose-slate max-w-none #{@class}"}>
      {Phoenix.HTML.raw(@html)}
      <%= for {mermaid, index} <- Enum.with_index(@mermaid_blocks) do %>
        <div id={"mermaid-#{index}"} phx-hook="Mermaid" data-mermaid={mermaid} class="my-4">
          <div class="flex items-center gap-2 text-base-content/50 text-sm py-4">
            <span class="loading loading-spinner loading-xs"></span> Rendering diagram...
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
