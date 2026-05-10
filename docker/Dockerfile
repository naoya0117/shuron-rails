ARG RUBY_VERSION=3.3
FROM docker.io/library/ruby:${RUBY_VERSION}-slim AS builder

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      build-essential git libyaml-dev pkg-config \
      libssl-dev libxml2-dev default-libmysqlclient-dev && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

ENV GEM_HOME=/usr/local/bundle
ENV PATH=/usr/local/bundle/bin:$PATH

COPY . /shuron-rails
WORKDIR /shuron-rails

# Build each component gem from source
RUN gem build activesupport/activesupport.gemspec && \
    gem build activemodel/activemodel.gemspec && \
    gem build actionview/actionview.gemspec && \
    gem build actionpack/actionpack.gemspec && \
    gem build activejob/activejob.gemspec && \
    gem build activerecord/activerecord.gemspec && \
    gem build actionmailer/actionmailer.gemspec && \
    gem build activestorage/activestorage.gemspec && \
    gem build actioncable/actioncable.gemspec && \
    gem build actionmailbox/actionmailbox.gemspec && \
    gem build actiontext/actiontext.gemspec && \
    gem build railties/railties.gemspec && \
    gem build rails.gemspec

# Install in dependency order so each step finds forked deps already installed
RUN gem install --no-document activesupport-*.gem && \
    gem install --no-document activemodel-*.gem && \
    gem install --no-document actionview-*.gem && \
    gem install --no-document actionpack-*.gem && \
    gem install --no-document activejob-*.gem && \
    gem install --no-document activerecord-*.gem && \
    gem install --no-document actionmailer-*.gem && \
    gem install --no-document activestorage-*.gem && \
    gem install --no-document actioncable-*.gem && \
    gem install --no-document actionmailbox-*.gem && \
    gem install --no-document actiontext-*.gem && \
    gem install --no-document railties-*.gem && \
    gem install --no-document rails-*.gem

FROM docker.io/library/ruby:${RUBY_VERSION}-slim

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      build-essential git libyaml-dev pkg-config \
      libssl-dev libxml2-dev \
      curl libjemalloc2 libvips sqlite3 && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

ENV GEM_HOME=/usr/local/bundle
ENV GEM_PATH=/usr/local/bundle
ENV PATH=/usr/local/bundle/bin:$PATH

COPY --from=builder /usr/local/bundle /usr/local/bundle

WORKDIR /rails

CMD ["bash"]
