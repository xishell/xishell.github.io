module Jekyll
  # auto-set per-post og:image (consumed by jekyll-seo-tag)
  Hooks.register :posts, :pre_render do |post|
    post.data['image'] ||= "/og/#{post.data['slug']}.png"
  end

  # one SVG per post at /og/<slug>.svg, converted to PNG by CI
  class OgImagePage < Page
    def initialize(site, post)
      @site = site
      @base = site.source
      @dir  = 'og'
      @name = "#{post.data['slug']}.svg"
      process(@name)
      self.data = {
        'layout' => 'og-svg',
        'title'  => post.data['title'],
        'date'   => post.data['date'],
        'tags'   => post.data['tags'],
        'slug'   => post.data['slug']
      }
      self.content = ''
    end
  end

  class OgImageGenerator < Generator
    safe true
    priority :low
    def generate(site)
      site.posts.docs.each do |post|
        site.pages << OgImagePage.new(site, post)
      end
    end
  end
end
