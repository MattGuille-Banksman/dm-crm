<template>
  <div
    v-if="!!page"
    class="d-flex w-100 overflow-hidden"
  >
    <portal
      v-if="!isRecordPage"
      to="topbar-title"
    >
      {{ pageTitle }}
    </portal>

    <!-- DM-CRM: page editing lives in the sidebar's Admin menu -->
    <portal
      v-if="!isRecordPage && page && page.canUpdatePage"
      to="sidebar-admin-tools"
    >
      <b-dropdown-item
        data-test-id="button-page-builder"
        :to="pageBuilder"
      >
        <font-awesome-icon
          :icon="['fas', 'tools']"
          class="mr-2"
        />
        {{ $t('general:label.pageBuilder') }}
      </b-dropdown-item>

      <b-dropdown-item
        data-test-id="button-page-edit"
        :to="pageEditor"
      >
        <font-awesome-icon
          :icon="['far', 'edit']"
          class="mr-2"
        />
        {{ $t('tooltip.edit.page') }}
      </b-dropdown-item>
    </portal>

    <div
      class="flex-grow-1 overflow-auto d-flex p-2 w-100"
    >
      <router-view
        v-if="isRecordPage"
        :namespace="namespace"
        :module="module"
        :page="page"
      />

      <div
        v-else-if="!layout"
        class="d-flex align-items-center justify-content-center w-100"
      >
        <b-spinner />
      </div>

      <grid
        v-else-if="blocks"
        :namespace="namespace"
        :module="module"
        :page="page"
        :blocks="blocks"
      />
    </div>

    <record-modal
      :namespace="namespace"
    />

    <magnification-modal
      :namespace="namespace"
    />
  </div>
</template>
<script>
import { mapGetters, mapActions } from 'vuex'
import Grid from 'corteza-webapp-compose/src/components/Public/Page/Grid'
import unsavedBlocks from 'corteza-webapp-compose/src/mixins/unsavedBlocks'
import RecordModal from 'corteza-webapp-compose/src/components/Public/Record/Modal'
import MagnificationModal from 'corteza-webapp-compose/src/components/Public/Page/Block/Modal'
import { NoID } from '@cortezaproject/corteza-js'
import page from 'corteza-webapp-compose/src/mixins/page'

export default {
  i18nOptions: {
    namespaces: 'page',
  },

  components: {
    Grid,
    RecordModal,
    MagnificationModal,
  },

  mixins: [
    page,
    unsavedBlocks,
  ],

  beforeRouteLeave (to, from, next) {
    if (!this.confirmUnsavedBlocks()) {
      next(false)
      return
    }

    this.setPreviousPages([])
    next()
  },

  beforeRouteUpdate (to, from, next) {
    if (!this.confirmUnsavedBlocks()) {
      next(false)
      return
    }

    const { recordID: toRecordID } = to.params
    const { recordID: fromRecordID } = from.params

    // Update either if coming from a record page and going to another record page and if the record isn't yet in previous pages to (avoid loop)
    const fromToRecordPage = fromRecordID && toRecordID !== fromRecordID
    // or if going from normal to record page
    const fromNormalToRecordPage = from.name === 'page' && to.name !== 'page'

    if (fromNormalToRecordPage || fromToRecordPage) {
      this.pushPreviousPages(from)
    }

    next()
  },

  data () {
    return {
      pageTitle: '',
    }
  },

  computed: {
    ...mapGetters({
      recordPaginationUsable: 'ui/recordPaginationUsable',
    }),

    module () {
      if (this.page.moduleID && this.page.moduleID !== NoID) {
        return this.$store.getters['module/getByID'](this.page.moduleID)
      }

      return undefined
    },

    uniqueID () {
      return [this.page.pageID, this.$route.query.layoutID]
    },
  },

  watch: {
    uniqueID: {
      immediate: true,
      handler (value = [], oldValue = []) {
        const [pageID = '', pageLayoutID = ''] = value
        const [oldPageID = ''] = oldValue

        if (!pageID || pageID === NoID) return

        if (pageID !== oldPageID) {
          this.layouts = this.getPageLayouts(this.page.pageID)
          this.layout = undefined
          this.pageTitle = this.page.title
        }

        if (!this.isRecordPage) {
          this.determineLayout({ pageLayoutID }).then(blocks => {
            if (blocks) {
              this.blocks = blocks
            }
          }).finally(() => {
            this.processing = false
          })
        }

        // If the page changed we need to clear the record pagination since its not relevant anymore
        if (this.recordPaginationUsable) {
          this.setRecordPaginationUsable(false)
        } else if (pageID !== oldPageID) {
          this.clearRecordSet()
          this.clearRecordPagination()
        }
      },
    },

    'page.handle': {
      immediate: true,
      handler (handle, oldHandle) {
        if (handle !== oldHandle) {
          this.setPageHandle(handle)
        }
      },
    },

    'layout.handle': {
      immediate: true,
      handler (handle, oldHandle) {
        if (handle !== oldHandle) {
          this.setLayoutHandle(handle)
        }
      },
    },
  },

  beforeDestroy () {
    this.setPageHandle('')
    this.setLayoutHandle('')
    this.setDefaultValues()
    this.clearRecordSet()
  },

  methods: {
    ...mapActions({
      setRecordPaginationUsable: 'ui/setRecordPaginationUsable',
      clearRecordPagination: 'ui/clearRecordPagination',
      setPreviousPages: 'ui/setPreviousPages',
      pushPreviousPages: 'ui/pushPreviousPages',
      setPageHandle: 'ui/setPageHandle',
      setLayoutHandle: 'ui/setLayoutHandle',
      setRecordPageHandle: 'ui/setRecordPageHandle',
    }),

    setDefaultValues () {
      this.layouts = []
      this.layout = undefined
      this.blocks = undefined
      this.pageTitle = ''
    },
  },
}
</script>
