ARG RUBY_VERSION=3.3
FROM docker.io/library/ruby:${RUBY_VERSION}-slim AS gem-builder

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      build-essential git libyaml-dev pkg-config \
      libssl-dev libxml2-dev default-libmysqlclient-dev && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

ENV GEM_HOME=/usr/local/bundle
ENV PATH=/usr/local/bundle/bin:$PATH

COPY . /shuron-rails
WORKDIR /shuron-rails

RUN mkdir /gems && \
    for dir in activesupport activemodel actionview actionpack activejob activerecord \
                actionmailer activestorage actioncable actionmailbox actiontext railties; do \
      (cd $dir && gem build ${dir}.gemspec && mv *.gem /gems/); \
    done && \
    gem build rails.gemspec && mv *.gem /gems/

WORKDIR /gems
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

COPY --from=gem-builder /usr/local/bundle /usr/local/bundle

WORKDIR /rails

# env -u GEM_PATH allows Ruby to find bundled gems (e.g. minitest) from the system path
RUN env -u GEM_PATH rails new . --skip-bundle --force && \
    sed -i 's/^gem "rails", "~> .*"/gem "rails", "8.1.2"/' Gemfile && \
    bundle install

EXPOSE 3000
CMD ["bin/rails", "server", "-b", "0.0.0.0"]
